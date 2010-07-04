# -*- encoding: binary -*-
require 'rainbows/tee_input'

# base class for Rainbows concurrency models, this is currently used by
# ThreadSpawn and ThreadPool models.  Base is also its own
# (non-)concurrency model which is basically Unicorn-with-keepalive, and
# not intended for production use, as keepalive with a pure prefork
# concurrency model is extremely expensive.
module Rainbows::Base

  # :stopdoc:
  include Rainbows::Const
  include Rainbows::HttpResponse

  # shortcuts...
  G = Rainbows::G
  NULL_IO = Unicorn::HttpRequest::NULL_IO
  TeeInput = Rainbows::TeeInput
  HttpParser = Unicorn::HttpParser

  # this method is called by all current concurrency models
  def init_worker_process(worker)
    super(worker)
    Rainbows::HttpResponse.setup(self.class)
    Rainbows::MaxBody.setup
    G.tmp = worker.tmp

    # avoid spurious wakeups and blocking-accept() with 1.8 green threads
    if ! defined?(RUBY_ENGINE) && RUBY_VERSION.to_f < 1.9
      require "io/nonblock"
      Rainbows::HttpServer::LISTENERS.each { |l| l.nonblock = true }
    end

    # we're don't use the self-pipe mechanism in the Rainbows! worker
    # since we don't defer reopening logs
    Rainbows::HttpServer::SELF_PIPE.each { |x| x.close }.clear
    trap(:USR1) { reopen_worker_logs(worker.nr) }
    trap(:QUIT) { G.quit! }
    [:TERM, :INT].each { |sig| trap(sig) { exit!(0) } } # instant shutdown
    logger.info "Rainbows! #@use worker_connections=#@worker_connections"
  end

  def wait_headers_readable(client)
    IO.select([client], nil, nil, G.kato)
  end

  # once a client is accepted, it is processed in its entirety here
  # in 3 easy steps: read request, call app, write app response
  # this is used by synchronous concurrency models
  #   Base, ThreadSpawn, ThreadPool
  def process_client(client)
    buf = client.readpartial(CHUNK_SIZE) # accept filters protect us here
    hp = HttpParser.new
    env = {}
    alive = true
    remote_addr = Rainbows.addr(client)

    begin # loop
      until hp.headers(env, buf)
        wait_headers_readable(client) or return
        buf << client.readpartial(CHUNK_SIZE)
      end

      env[CLIENT_IO] = client
      env[RACK_INPUT] = 0 == hp.content_length ?
                        NULL_IO : TeeInput.new(client, env, hp, buf)
      env[REMOTE_ADDR] = remote_addr
      response = app.call(env.update(RACK_DEFAULTS))

      if 100 == response[0].to_i
        client.write(EXPECT_100_RESPONSE)
        env.delete(HTTP_EXPECT)
        response = app.call(env)
      end

      alive = hp.keepalive? && G.alive
      out = [ alive ? CONN_ALIVE : CONN_CLOSE ] if hp.headers?
      write_response(client, response, out)
    end while alive and hp.reset.nil? and env.clear
  # if we get any error, try to write something back to the client
  # assuming we haven't closed the socket, but don't get hung up
  # if the socket is already closed or broken.  We'll always ensure
  # the socket is closed at the end of this function
  rescue => e
    Rainbows::Error.write(client, e)
  ensure
    client.close unless client.closed?
  end

  def self.included(klass)
    klass.const_set :LISTENERS, Rainbows::HttpServer::LISTENERS
    klass.const_set :G, Rainbows::G
  end

  # :startdoc:
end
