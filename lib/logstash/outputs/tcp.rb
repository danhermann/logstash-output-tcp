# encoding: utf-8
require "logstash/outputs/base"
require "logstash/namespace"
require "thread"
require "logstash/util/socket_peer"

# Write events over a TCP socket.
#
# Each event json is separated by a newline.
#
# Can either accept connections from clients or connect to a server,
# depending on `mode`.
class LogStash::Outputs::Tcp < LogStash::Outputs::Base

  config_name "tcp"

  default :codec, "json"

  # When mode is `server`, the address to listen on.
  # When mode is `client`, the address to connect to.
  config :host, :validate => :string, :required => true

  # When mode is `server`, the port to listen on.
  # When mode is `client`, the port to connect to.
  config :port, :validate => :number, :required => true

  # When connect failed,retry interval in sec.
  config :reconnect_interval, :validate => :number, :default => 10

  # Mode to operate in. `server` listens for client connections,
  # `client` connects to a server.
  config :mode, :validate => ["server", "client"], :default => "client"

  class Client
    public
    def initialize(socket, logger)
      @socket = socket
      @logger = logger
      @queue  = Queue.new
    end

    public
    def run
      loop do
        begin
          @socket.write(@queue.pop)
        rescue => e
          @logger.warn("tcp output exception", :socket => @socket,
                       :exception => e)
          break
        end
      end
    end # def run

    public
    def write(msg)
      @queue.push(msg)
    end # def write
  end # class Client

  public
  def register
    require "socket"
    require "stud/try"
    if server?
      workers_not_supported

      @logger.info("Starting tcp output listener", :address => "#{@host}:#{@port}")
      begin
        @server_socket = TCPServer.new(@host, @port)
      rescue Errno::EADDRINUSE
        @logger.error("Could not start TCP server: Address in use",
                      :host => @host, :port => @port)
        raise
      end
      @client_threads = []

      @accept_thread = Thread.new(@server_socket) do |server_socket|
        loop do
          Thread.start(server_socket.accept) do |client_socket|
            # monkeypatch a 'peer' method onto the socket.
            client_socket.instance_eval { class << self; include ::LogStash::Util::SocketPeer end }
            @logger.debug("Accepted connection", :client => client_socket.peer,
                          :server => "#{@host}:#{@port}")
            client = Client.new(client_socket, @logger)
            Thread.current[:client] = client
            @client_threads << Thread.current
            client.run
          end
        end
      end

      @codec.on_event do |event, payload|
        @client_threads.each do |client_thread|
          client_thread[:client].write(payload)
        end
        @client_threads.reject! {|t| !t.alive? }
      end
    else
      client_socket = nil
      @codec.on_event do |event, payload|
        begin
          client_socket = connect unless client_socket
          r,w,e = IO.select([client_socket], [client_socket], [client_socket], nil)
          # don't expect any reads, but a readable socket might
          # mean the remote end closed, so read it and throw it away.
          # we'll get an EOFError if it happens.
          client_socket.sysread(16384) if r.any?

          # Now send the payload
          client_socket.syswrite(payload) if w.any?
        rescue => e
          @logger.warn("tcp output exception", :host => @host, :port => @port,
                       :exception => e, :backtrace => e.backtrace)
          client_socket.close rescue nil
          client_socket = nil
          sleep @reconnect_interval
          retry
        end
      end
    end
  end # def register

  private
  def connect
    Stud::try do
      client_socket = TCPSocket.new(@host, @port)
      client_socket.instance_eval { class << self; include ::LogStash::Util::SocketPeer end }
      @logger.debug("Opened connection", :client => "#{client_socket.peer}")
      return client_socket
    end
  end # def connect

  private
  def server?
    @mode == "server"
  end # def server?

  public
  def receive(event)
    @codec.encode(event)
  end # def receive
end # class LogStash::Outputs::Tcp
