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
  #
  # At most *max_connections* connections are served at once (RF3): with
  # that many open, the loop waits for one to end before it accepts the
  # next, which waits in the listen queue meanwhile. The handler bounds the
  # connections of each user within that.
  class Server
    # The most connections the server serves at once.
    MAX_CONNECTIONS = 64

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
    # How often the loop, waiting at the connection limit, checks whether
    # the listener was closed.
    SLOT_CHECK_INTERVAL = 100.milliseconds

    # A server that accepts on *listener*, hands each connection to *handler*
    # and returns from `run` once *registry* is empty and nothing happened for
    # *idle*. The daemon keeps the default *max_connections*; raises
    # `ArgumentError` when it is below 1.
    def initialize(@listener : UNIXServer, *, @handler : Handler, @registry : Registry,
                   @idle : Time::Span = 30.seconds, @max_connections : Int32 = MAX_CONNECTIONS,
                   @log : Log = Log.for("tunnelgeist.server"))
      raise ArgumentError.new("max_connections must be at least 1, not #{@max_connections}") if @max_connections < 1

      @idle_since = Time.instant
      # Holds one element per connection being served; a send waits while
      # it is full.
      @slots = Channel(Nil).new(@max_connections)
    end

    # Serves connections until the server is idle, then closes the
    # listener and returns. Closing the listener from elsewhere also ends
    # it, within `SLOT_CHECK_INTERVAL` when the loop waits at the connection
    # limit; the connections being served then run on in their fibers.
    def run : Nil
      @idle_since = Time.instant
      spawn(name: "tunnelgeist.idle") { watch_idle }
      loop do
        break unless take_slot

        socket = accept
        unless socket
          @slots.receive
          break
        end

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

    # Takes a connection slot, waiting while `max_connections` connections
    # are being served, and returns true; returns false, taking none, once
    # the listener is closed, which the wait checks every
    # `SLOT_CHECK_INTERVAL` so a signal or the idle check is not held up
    # until a connection ends. The wait is logged, so the operator sees why
    # clients hang.
    private def take_slot : Bool
      select
      when @slots.send(nil)
        return true
      else
        @log.warn { "connection limit of #{@max_connections} reached, waiting for a connection to end" }
      end
      until @listener.closed?
        select
        when @slots.send(nil)
          return true
        when timeout(SLOT_CHECK_INTERVAL)
        end
      end
      false
    end

    private def serve(socket : UNIXSocket) : Nil
      @handler.handle(socket)
    ensure
      @open_connections.sub(1)
      @slots.receive
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
