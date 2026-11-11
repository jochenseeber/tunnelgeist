require "../test_helper"
require "socket"
require "../../src/tunnelgeist/server"
require "../../spec/tunnelgeist/support/client_configs"
require "../../spec/tunnelgeist/support/server_runs"
require "./support/temporary_directory"

# The accept loop of the daemon at its connection limit, with clients
# connecting to its socket as they do to the daemon's and the handler's
# collaborators replaced by fakes.
describe TunnelgeistServer do
  {% if flag?(:darwin) %}
    include TunnelgeistServerRuns

    # Connects to *path* and asks as `ask` does; *clients* collects the
    # connection for the caller to close.
    def ask(path : String, *, clients : Array(UNIXSocket)) : Channel(String)
      client = UNIXSocket.new(path)
      clients << client
      ask(client)
    end

    # Whether every channel of *replies* receives an error reply within
    # *within* of the call.
    def answered?(replies : Array(Channel(String)), *, within : Time::Span) : Bool
      deadline = Time.instant + within
      replies.all? do |reply|
        line = reply_within(reply, within: {deadline - Time.instant, Time::Span.zero}.max)
        !line.nil? && line.includes?(%("ok":false))
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
          finished = returned?(done, within: 1.second)

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
