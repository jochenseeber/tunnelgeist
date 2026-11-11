{% skip_file unless flag?(:darwin) %}

require "log"
require "socket"
require "./handler"
require "./registry"

module Tunnelgeist
  # The accept loop of the daemon (UA5): one fiber per connection, each
  # served by the `Handler`. `run` returns once no connection is open, no
  # device is registered and *idle* has passed since that last became true
  # (or since the start); launchd starts the daemon again on the next
  # connection.
  #
  # The open connection count and the idle clock change only in fibers of
  # the server's execution context; the count is atomic so a handler fiber
  # on another thread could not lose an update either.
  class Server
    @open_connections = Atomic(Int32).new(0)
    # Set on each accept, so a connection that opens and closes between two
    # idle checks still restarts the idle clock.
    @accepted = Atomic(Bool).new(false)
    @idle_since : Time::Instant

    # The first wait after a failed accept; it doubles up to
    # `MAX_ACCEPT_BACKOFF`.
    ACCEPT_BACKOFF = 100.milliseconds
    # The longest wait after a failed accept.
    MAX_ACCEPT_BACKOFF = 1.second

    # A server that accepts on *listener*, hands each connection to *handler*
    # and returns from `run` once *registry* is empty and nothing happened for
    # *idle*.
    def initialize(@listener : UNIXServer, *, @handler : Handler, @registry : Registry,
                   @idle : Time::Span = 30.seconds, @log : Log = Log.for("tunnelgeist.server"))
      @idle_since = Time.instant
    end

    # Serves connections until the server is idle, then closes the
    # listener and returns. Closing the listener from elsewhere also ends
    # it.
    def run : Nil
      @idle_since = Time.instant
      spawn(name: "tunnelgeist.idle") { watch_idle }
      loop do
        socket = accept
        break unless socket

        @open_connections.add(1)
        @accepted.set(true)
        spawn(name: "tunnelgeist.connection") { serve(socket) }
      end
    end

    # The next connection, or nil once the listener is closed. Any other
    # accept failure (`EMFILE`, `ENFILE`, `ECONNABORTED`, ...) is logged and
    # retried after a growing pause: a client must not be able to stop the
    # daemon and so forget every device.
    private def accept : UNIXSocket?
      backoff = ACCEPT_BACKOFF
      loop do
        connection = @listener.accept?
        return connection
      rescue ex : IO::Error
        # The idle fiber or a signal closed the listener while it waited.
        return if @listener.closed?

        @log.warn { "accept failed, retrying in #{backoff.total_milliseconds.to_i} ms: #{ex.message}" }
        sleep backoff
        backoff = {backoff * 2, MAX_ACCEPT_BACKOFF}.min
      end
    end

    private def serve(socket : UNIXSocket) : Nil
      @handler.handle(socket)
    ensure
      @open_connections.sub(1)
    end

    # Checks the idle rule a few times per idle period and closes the
    # listener, which ends `accept`, once it holds. The idle clock starts
    # at the first check that finds the server idle, so it never runs
    # shorter than *idle*, and at most one check interval longer.
    private def watch_idle : Nil
      interval = {@idle / 10, 1.second}.min
      busy = false
      until @listener.closed?
        sleep interval
        if @accepted.swap(false) || @open_connections.get > 0 || !@registry.empty?
          busy = true
        elsif busy
          busy = false
          @idle_since = Time.instant
        elsif @idle_since.elapsed >= @idle
          @listener.close
        end
      end
    end
  end
end
