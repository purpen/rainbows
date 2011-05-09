# -*- encoding: binary -*-
require 'kgio'
require 'unicorn'
require 'io/wait'
Unicorn::SocketHelper::DEFAULTS.merge!({
  # the value passed to TCP_DEFER_ACCEPT actually matters in Linux 2.6.32+
  :tcp_defer_accept => 60,

  # keep-alive performance sucks without this due to
  # write(headers)-write(body)-read
  # because we always write headers and bodies with two calls
  :tcp_nodelay => true,

  # we always want to send our headers out ASAP since Rainbows!
  # is designed for apps that could trickle out the body slowly
  :tcp_nopush => false,
})

module Rainbows

  O = {} # :nodoc:

  # map of numeric file descriptors to IO objects to avoid using IO.new
  # and potentially causing race conditions when using /dev/fd/
  FD_MAP = {}
  FD_MAP.compare_by_identity if FD_MAP.respond_to?(:compare_by_identity)

  # :startdoc:

  require 'rainbows/const'
  require 'rainbows/http_parser'
  require 'rainbows/http_server'
  autoload :Response, 'rainbows/response'
  autoload :ProcessClient, 'rainbows/process_client'
  autoload :Client, 'rainbows/client'
  autoload :Base, 'rainbows/base'
  autoload :Sendfile, 'rainbows/sendfile'
  autoload :AppPool, 'rainbows/app_pool'
  autoload :DevFdResponse, 'rainbows/dev_fd_response'
  autoload :MaxBody, 'rainbows/max_body'
  autoload :QueuePool, 'rainbows/queue_pool'
  autoload :EvCore, 'rainbows/ev_core'
  autoload :SocketProxy, 'rainbows/socket_proxy'

  # Sleeps the current application dispatch.  This will pick the
  # optimal method to sleep depending on the concurrency model chosen
  # (which may still suck and block the entire process).  Using this
  # with the basic :Coolio or :EventMachine models is not recommended.
  # This should be used within your Rack application.
  def self.sleep(nr)
    case Rainbows.server.use
    when :FiberPool, :FiberSpawn
      Rainbows::Fiber.sleep(nr)
    when :RevFiberSpawn, :CoolioFiberSpawn
      Rainbows::Fiber::Coolio::Sleeper.new(nr)
    when :Revactor
      Actor.sleep(nr)
    else
      Kernel.sleep(nr)
    end
  end

  # runs the Rainbows! HttpServer with +app+ and +options+ and does
  # not return until the server has exited.
  def self.run(app, options = {}) # :nodoc:
    HttpServer.new(app, options).start.join
  end

  # :stopdoc:
  class << self
    attr_accessor :client_header_buffer_size
    attr_accessor :client_max_body_size
    attr_accessor :keepalive_timeout
    attr_accessor :server
    attr_accessor :cur # may not always be used
    attr_reader :alive
    attr_writer :tick_io
  end
  # :startdoc:

  def self.defaults!
    # the default max body size is 1 megabyte (1024 * 1024 bytes)
    @client_max_body_size = 1024 * 1024

    # the default keepalive_timeout is 5 seconds
    @keepalive_timeout = 5

    # 1024 bytes matches nginx, though Rails session cookies will typically
    # need >= 1500...
    @client_header_buffer_size = 1024
  end

  defaults!

  # :stopdoc:
  @alive = true
  @cur = 0
  @tick_mod = 0
  @expire = nil

  def self.tick
    @tick_io.chmod(@tick_mod = 0 == @tick_mod ? 1 : 0)
    exit!(2) if @expire && Time.now >= @expire
    @alive && @server.master_pid == Process.ppid or quit!
  end

  def self.cur_alive
    @alive || @cur > 0
  end

  def self.quit!
    unless @expire
      @alive = false
      Rainbows::HttpParser.quit
      @expire = Time.now + (@server.timeout * 2.0)
      Unicorn::HttpServer::LISTENERS.each { |s| s.close rescue nil }.clear
    end
    false
  end

  autoload :Base, "rainbows/base"
  autoload :WriterThreadPool, "rainbows/writer_thread_pool"
  autoload :WriterThreadSpawn, "rainbows/writer_thread_spawn"
  autoload :Revactor, "rainbows/revactor"
  autoload :ThreadSpawn, "rainbows/thread_spawn"
  autoload :ThreadPool, "rainbows/thread_pool"
  autoload :Rev, "rainbows/rev"
  autoload :RevThreadSpawn, "rainbows/rev_thread_spawn"
  autoload :RevThreadPool, "rainbows/rev_thread_pool"
  autoload :RevFiberSpawn, "rainbows/rev_fiber_spawn"
  autoload :Coolio, "rainbows/coolio"
  autoload :CoolioThreadSpawn, "rainbows/coolio_thread_spawn"
  autoload :CoolioThreadPool, "rainbows/coolio_thread_pool"
  autoload :CoolioFiberSpawn, "rainbows/coolio_fiber_spawn"
  autoload :Epoll, "rainbows/epoll"
  autoload :XEpoll, "rainbows/xepoll"
  autoload :EventMachine, "rainbows/event_machine"
  autoload :FiberSpawn, "rainbows/fiber_spawn"
  autoload :FiberPool, "rainbows/fiber_pool"
  autoload :ActorSpawn, "rainbows/actor_spawn"
  autoload :NeverBlock, "rainbows/never_block"
  autoload :XEpollThreadSpawn, "rainbows/xepoll_thread_spawn"
  autoload :XEpollThreadPool, "rainbows/xepoll_thread_pool"

  # :startdoc:
  autoload :Fiber, 'rainbows/fiber' # core class
  autoload :StreamFile, 'rainbows/stream_file'
  autoload :HttpResponse, 'rainbows/http_response' # deprecated
  autoload :ThreadTimeout, 'rainbows/thread_timeout'
  autoload :WorkerYield, 'rainbows/worker_yield'
  autoload :SyncClose, 'rainbows/sync_close'
  autoload :ReverseProxy, 'rainbows/reverse_proxy'
  autoload :JoinThreads, 'rainbows/join_threads'
end

require 'rainbows/error'
require 'rainbows/configurator'
