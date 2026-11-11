require "../spec_helper"
require "../../src/tunnelgeist/server"
require "./support/client_configs"
require "./support/temporary_directory"
require "./support/registrations"

# The accept loop of the daemon and its idle exit (UA5).
describe TunnelgeistServer do
  {% if flag?(:darwin) %}
    UTUN7 = Tunnelgeist::InterfaceName.new("utun7")

    def empty_addresses : Array(Tunnelgeist::Address)
      [] of Tunnelgeist::Address
    end

    def empty_routes : Array(Tunnelgeist::Prefix)
      [] of Tunnelgeist::Prefix
    end

    # A listener whose next `failures` accepts fail as `accept` does when the
    # process is out of descriptors.
    class FlakyListener < UNIXServer
      property failures = 0

      def accept? : UNIXSocket?
        if @failures > 0
          @failures -= 1
          raise Socket::Error.from_os_error("accept", Errno::EMFILE)
        end
        super
      end
    end

    # A server on a socket in a fresh temporary directory with fakes behind
    # its handler.
    record ServerFixture, server : Tunnelgeist::Server, path : String, registry : Tunnelgeist::Registry,
      backend : Log::MemoryBackend, listener : UNIXServer

    # Runs the block with a `ServerFixture`; its backend holds the server's log.
    def with_server(*, failures : Int32 = 0, max_connections : Int32 = Tunnelgeist::Server::MAX_CONNECTIONS, &)
      TunnelgeistTemporaryDirectory.with_temporary_directory do |directory|
        path = TunnelgeistTemporaryDirectory.socket_path(directory, name: "server")
        registry = Tunnelgeist::Registry.new
        handler = Tunnelgeist::Handler.new(registry,
          create_device: ->(_name : Tunnelgeist::InterfaceName?, _mtu : Int32) : Tunnelgeist::Device::Utun { raise "no device" },
          run: ->(_argv : Array(String)) { Tunnelgeist::CommandRunner::Result.new(exit_status: 0, output: "", error: "") },
          # A configuration that applies to every peer, so every request is read.
          admit: ->(_peer : Tunnelgeist::Peer) { TunnelgeistClientConfigs.applying([TunnelgeistClientConfigs.client("any")]) },
          group: "tunnelgeist",
          interface_index: ->(_name : Tunnelgeist::InterfaceName) { 0_u32 },
          log: Log.new("tunnelgeist", Log::MemoryBackend.new, :debug))
        listener = FlakyListener.new(path)
        listener.failures = failures
        backend = Log::MemoryBackend.new
        server = Tunnelgeist::Server.new(listener, handler: handler, registry: registry, idle: 100.milliseconds,
          max_connections: max_connections, log: Log.new("tunnelgeist.server", backend, :debug))
        begin
          yield ServerFixture.new(server: server, path: path, registry: registry, backend: backend, listener: listener)
        ensure
          listener.close
        end
      end
    end

    # Runs *server* in a fiber; the channel receives when `run` returns.
    def start(server : Tunnelgeist::Server) : Channel(Nil)
      done = Channel(Nil).new(1)
      spawn do
        server.run
        done.send(nil)
      end
      done
    end

    def returned?(done : Channel(Nil), *, within : Time::Span) : Bool
      select
      when done.receive
        true
      when timeout(within)
        false
      end
    end

    test "run returns once idle with an empty registry" do
      with_server do |fixture|
        done = start(fixture.server)
        finished = returned?(done, within: 500.milliseconds)
        assert(finished)
        assert(!File.exists?(fixture.path))
      end
    end

    test "run keeps running while a device is registered and returns once it is removed" do
      with_server do |fixture|
        TunnelgeistRegistrations.register(fixture.registry, UTUN7, index: 12_u32, addresses: empty_addresses, routes: empty_routes) { }
        done = start(fixture.server)
        running = !returned?(done, within: 500.milliseconds)
        assert(running)

        removed = Time.instant
        fixture.registry.remove(UTUN7)
        finished = returned?(done, within: 400.milliseconds)
        assert(finished)
        assert(removed.elapsed >= 100.milliseconds)
      end
    end

    test "run keeps running while a connection is open" do
      with_server do |fixture|
        done = start(fixture.server)
        client = UNIXSocket.new(fixture.path)
        begin
          running = !returned?(done, within: 300.milliseconds)
          assert(running)
        ensure
          client.close
        end
        finished = returned?(done, within: 500.milliseconds)
        assert(finished)
      end
    end

    test "run keeps serving through failed accepts and serves the next connection" do
      with_server(failures: 2) do |fixture|
        TunnelgeistRegistrations.register(fixture.registry, UTUN7, index: 12_u32, addresses: empty_addresses, routes: empty_routes) { }
        done = start(fixture.server)
        client = UNIXSocket.new(fixture.path)
        begin
          client.read_timeout = 2.seconds
          client.print("not json\n")
          reply = client.gets.to_s
          running = !returned?(done, within: 10.milliseconds)

          assert(reply.includes?(%("ok":false)))
          assert(running)
          assert(fixture.backend.entries.count(&.message.includes?("accept failed")) == 2)
        ensure
          client.close
        end
        fixture.registry.remove(UTUN7)
        finished = returned?(done, within: 500.milliseconds)
        assert(finished)
      end
    end

    # Sends a request that does not parse on *client* and reads the reply in
    # a fiber; the channel receives the reply line.
    def ask(client : UNIXSocket) : Channel(String)
      reply = Channel(String).new(1)
      client.print("not json\n")
      spawn { reply.send(client.gets.to_s) }
      reply
    end

    def received?(reply : Channel(String), *, within : Time::Span) : Bool
      select
      when reply.receive
        true
      when timeout(within)
        false
      end
    end

    test "run returns promptly when the listener closes while it waits at the connection limit" do
      with_server(max_connections: 1) do |fixture|
        done = start(fixture.server)
        idle = UNIXSocket.new(fixture.path)
        begin
          waiting = !returned?(done, within: 50.milliseconds)
          closed = Time.instant
          fixture.listener.close
          finished = returned?(done, within: 1.second)

          assert(waiting)
          assert(finished)
          assert(closed.elapsed < 500.milliseconds)
        ensure
          idle.close
        end
      end
    end

    test "run waits at the connection limit and accepts again once a connection ends" do
      with_server(max_connections: 1) do |fixture|
        assert(Tunnelgeist::Server::MAX_CONNECTIONS == 64)
        done = start(fixture.server)
        idle = UNIXSocket.new(fixture.path)
        waiting = UNIXSocket.new(fixture.path)
        begin
          reply = ask(waiting)
          waited = !received?(reply, within: 300.milliseconds)
          idle.close
          answered = received?(reply, within: 2.seconds)

          assert(waited)
          assert(answered)
          assert(fixture.backend.entries.any?(&.message.==("connection limit of 1 reached, waiting for a connection to end")))
        ensure
          idle.close
          waiting.close
        end
        finished = returned?(done, within: 500.milliseconds)
        assert(finished)
      end
    end

    test "new refuses a connection limit below 1" do
      TunnelgeistTemporaryDirectory.with_temporary_directory do |directory|
        listener = UNIXServer.new(TunnelgeistTemporaryDirectory.socket_path(directory, name: "server"))
        begin
          registry = Tunnelgeist::Registry.new
          handler = Tunnelgeist::Handler.new(registry, admit: ->(_peer : Tunnelgeist::Peer) { TunnelgeistClientConfigs.open_admission },
            group: "tunnelgeist", log: Log.new("tunnelgeist", Log::MemoryBackend.new, :debug))
          error = raised(ArgumentError) do
            Tunnelgeist::Server.new(listener, handler: handler, registry: registry, max_connections: 0)
          end
          assert(error.message == "max_connections must be at least 1, not 0")
        ensure
          listener.close
        end
      end
    end
  {% end %}
end
