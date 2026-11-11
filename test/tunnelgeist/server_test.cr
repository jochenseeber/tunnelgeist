require "../test_helper"
require "socket"
require "../../src/tunnelgeist/server"
require "../../spec/tunnelgeist/support/client_configs"
require "./support/temporary_directory"

# The accept loop of the daemon at its connection limit, with clients
# connecting to its socket as they do to the daemon's and the handler's
# collaborators replaced by fakes.
describe TunnelgeistServer do
  {% if flag?(:darwin) %}
    # Runs *server* in a fiber; the channel receives when `run` returns.
    def start(server : Tunnelgeist::Server) : Channel(Nil)
      done = Channel(Nil).new(1)
      spawn do
        server.run
        done.send(nil)
      end
      done
    end

    # Connects to *path*, sends a request that does not parse and reads the
    # reply in a fiber; the channel receives the reply line.
    def ask(path : String, *, clients : Array(UNIXSocket)) : Channel(String)
      client = UNIXSocket.new(path)
      clients << client
      reply = Channel(String).new(1)
      client.print("not json\n")
      spawn { reply.send(client.gets.to_s) }
      reply
    end

    # Whether every channel of *replies* receives an error reply within
    # *within*.
    def answered?(replies : Array(Channel(String)), *, within : Time::Span) : Bool
      deadline = Time.instant + within
      replies.all? do |reply|
        select
        when line = reply.receive
          line.includes?(%("ok":false))
        when timeout({deadline - Time.instant, Time::Span.zero}.max)
          false
        end
      end
    end

    test "a server at its connection limit serves the waiting clients once its connections end and then goes idle" do
      TunnelgeistTemporaryDirectory.with_temporary_directory do |directory|
        path = TunnelgeistTemporaryDirectory.socket_path(directory, name: "server")
        registry = Tunnelgeist::Registry.new
        handler = Tunnelgeist::Handler.new(registry,
          admit: ->(_peer : Tunnelgeist::Peer) { TunnelgeistClientConfigs.open_admission },
          group: "tunnelgeist",
          log: Log.new("tunnelgeist", Log::MemoryBackend.new, :debug))
        listener = UNIXServer.new(path)
        backend = Log::MemoryBackend.new
        server = Tunnelgeist::Server.new(listener, handler: handler, registry: registry, idle: 100.milliseconds,
          max_connections: 2, log: Log.new("tunnelgeist.server", backend, :debug))
        clients = [] of UNIXSocket
        begin
          done = start(server)
          holding = Array.new(2) { UNIXSocket.new(path) }
          clients.concat(holding)
          waiting = Array.new(2) { ask(path, clients: clients) }

          saturated = !answered?(waiting.first(1), within: 300.milliseconds)
          holding.each(&.close)
          recovered = answered?(waiting, within: 2.seconds)
          again = answered?([ask(path, clients: clients)], within: 2.seconds)
          clients.each(&.close)
          finished = select
          when done.receive
            true
          when timeout(1.second)
            false
          end

          assert(saturated)
          assert(recovered)
          assert(again)
          assert(finished)
          assert(backend.entries.any?(&.message.==("connection limit of 2 reached, waiting for a connection to end")))
        ensure
          clients.each(&.close)
          listener.close
        end
      end
    end
  {% end %}
end
