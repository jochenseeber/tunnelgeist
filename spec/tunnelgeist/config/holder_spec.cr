require "log"
require "../../spec_helper"
require "../../../src/tunnelgeist/config/holder"
require "../support/client_configs"
require "../support/fake_membership"
require "../support/fake_peer"

# The running configuration and its swap on `SIGHUP` (CA4, CA5, CD4, CN4),
# with configurations built by hand, groups whose members the spec names,
# a peer built by hand and loaders that stand in for `Config.load`.
describe Tunnelgeist::Config::Holder do
  {% if flag?(:darwin) %}
    include TunnelgeistClientConfigs
    include TunnelgeistFakePeer

    alias Config = Tunnelgeist::Config
    alias Holder = Tunnelgeist::Config::Holder

    # The socket of the configuration a holder starts with, and the one it
    # listens on unless a test says otherwise.
    SOCKET = "/var/run/tg.sock"

    # The main group's membership: `staff` holds the peer `fake_peer`
    # builds, any other group nobody.
    def membership(group : String) : Tunnelgeist::Membership
      members = group == "staff" ? [PEER_UID] : [] of UInt32
      TunnelgeistFakeMembership.new(group, gid: 20_u32, members: members).as(Tunnelgeist::Membership)
    end

    # A configuration of the main group *group* with one client `name` that
    # allows the routes *routes*, and the socket *socket*.
    def config(name : String, *, routes : Array(String), socket : String = SOCKET, group : String = "staff") : Config
      Config.new(socket: socket, group: group, membership: membership(group), clients: [client(name, routes: routes)])
    end

    # A holder of *config* for a daemon that listens on *listening*.
    def holder(config : Config, *, listening : String = SOCKET) : Holder
      Holder.new(config, listening: listening)
    end

    # The route *route* the peer `fake_peer` builds is denied by the
    # holder's authorizer as it is now, nil when it is allowed.
    def route_denial(holder : Holder, *, route : String) : Tunnelgeist::Authorizer::Denial?
      holder.authorizer.admit(fake_peer).allow(addresses: [] of Tunnelgeist::Address, routes: [prefix(route)])
    end

    # A log that keeps its entries in *backend*.
    def memory_log(backend : Log::MemoryBackend) : Log
      Log.new("tunnelgeist", backend, :debug)
    end

    # The messages *backend* captured, each with its severity.
    def messages(backend : Log::MemoryBackend) : Array(String)
      backend.entries.map { |entry| "#{entry.severity.label} #{entry.message}" }
    end

    test "current and authorizer start from the configuration given" do
      first = config("first", routes: ["10.77.0.0/16"])
      holder = holder(first)

      assert(holder.current == first)
      assert(route_denial(holder, route: "10.77.0.0/16").nil?)
      assert(!route_denial(holder, route: "10.78.0.0/16").nil?)
    end

    test "replace swaps the configuration and the authorizer built from it" do
      holder = holder(config("first", routes: ["10.77.0.0/16"]))
      second = config("second", routes: ["10.78.0.0/16"])
      before = holder.authorizer

      holder.replace(second)

      assert(holder.current == second)
      assert(!holder.authorizer.same?(before))
      assert(route_denial(holder, route: "10.78.0.0/16").nil?)
      assert(!route_denial(holder, route: "10.77.0.0/16").nil?)
    end

    test "a successful reload swaps the configuration, so a route refused before is allowed after, and logs it" do
      holder = holder(config("first", routes: ["10.77.0.0/16"]))
      second = Config.new(socket: SOCKET, group: "staff", membership: membership("staff"),
        clients: [client("a", routes: ["10.78.0.0/16"]), client("b")])
      backend = Log::MemoryBackend.new
      assert(!route_denial(holder, route: "10.78.0.0/16").nil?)

      holder.reload(load: -> { second }, log: memory_log(backend))

      assert(holder.current.clients == second.clients)
      assert(route_denial(holder, route: "10.78.0.0/16").nil?)
      assert(messages(backend) == ["INFO configuration reloaded clients=2"])
    end

    test "a reload whose loader raises Config::Error keeps the old configuration and logs the failure" do
      first = config("first", routes: ["10.77.0.0/16"])
      holder = holder(first)
      before = holder.authorizer
      backend = Log::MemoryBackend.new
      failing = -> : Config { raise Config::Error.new("malformed JSON: unexpected token", file: "/etc/tg/config.json") }

      holder.reload(load: failing, log: memory_log(backend))

      assert(holder.current == first)
      assert(holder.authorizer.same?(before))
      assert(route_denial(holder, route: "10.77.0.0/16").nil?)
      assert(messages(backend) == [
        "ERROR configuration reload failed: /etc/tg/config.json: malformed JSON: unexpected token",
      ])
    end

    test "a reload whose loader raises anything else keeps the old configuration and logs the failure with the error" do
      first = config("first", routes: ["10.77.0.0/16"])
      holder = holder(first)
      before = holder.authorizer
      backend = Log::MemoryBackend.new
      error = RuntimeError.new("getgrnam_r: directory service unavailable")

      holder.reload(load: -> : Config { raise error }, log: memory_log(backend))

      assert(holder.current == first)
      assert(holder.authorizer.same?(before))
      assert(messages(backend) == [
        "ERROR configuration reload failed: RuntimeError: getgrnam_r: directory service unavailable",
      ])
      assert(backend.entries.first.exception.same?(error))
    end

    test "a reload with another socket applies the rest and logs that the socket needs a reinstall" do
      holder = holder(config("first", routes: ["10.77.0.0/16"]))
      moved = config("moved", routes: ["10.78.0.0/16"], socket: "/var/run/elsewhere.sock")
      backend = Log::MemoryBackend.new

      holder.reload(load: -> { moved }, log: memory_log(backend))

      assert(holder.current.clients == moved.clients)
      assert(holder.current.socket == moved.socket)
      assert(route_denial(holder, route: "10.78.0.0/16").nil?)
      assert(messages(backend) == [
        "INFO configuration reloaded clients=1",
        "WARN configuration socket changed to /var/run/elsewhere.sock, reinstall to apply",
      ])
    end

    test "the socket is compared with the one the daemon listens on, so moving it back logs no hint" do
      holder = holder(config("first", routes: ["10.77.0.0/16"]))
      log = memory_log(Log::MemoryBackend.new)
      holder.reload(load: -> { config("moved", routes: [] of String, socket: "/var/run/elsewhere.sock") }, log: log)
      backend = Log::MemoryBackend.new

      holder.reload(load: -> { config("back", routes: [] of String) }, log: memory_log(backend))

      assert(holder.current.socket == SOCKET)
      assert(messages(backend) == ["INFO configuration reloaded clients=1"])
    end

    test "a reload whose socket is not the one launchd passed logs the hint even when the file did not change" do
      holder = holder(config("first", routes: [] of String), listening: "/var/run/launchd.sock")
      backend = Log::MemoryBackend.new

      holder.reload(load: -> { config("same", routes: [] of String) }, log: memory_log(backend))

      assert(messages(backend) == [
        "INFO configuration reloaded clients=1",
        "WARN configuration socket changed to /var/run/tg.sock, reinstall to apply",
      ])
    end

    test "a reload with another group keeps the running group and its membership, applies the clients and logs the hint" do
      first = config("first", routes: ["10.77.0.0/16"])
      holder = holder(first)
      backend = Log::MemoryBackend.new

      holder.reload(load: -> { config("second", routes: ["10.78.0.0/16"], group: "wheel") }, log: memory_log(backend))

      assert(holder.current.group == "staff")
      assert(holder.current.membership.same?(first.membership))
      assert(holder.current.clients.map(&.name) == ["second"])
      # The peer is in staff but not in wheel: an allowed route shows the
      # staff membership still decides.
      assert(route_denial(holder, route: "10.78.0.0/16").nil?)
      assert(messages(backend) == [
        "INFO configuration reloaded clients=1",
        "WARN configuration group changed to wheel, reinstall to apply",
      ])
    end
  {% end %}
end
