require "socket"
require "../spec_helper"
require "../../src/tunnelgeist/authorizer"
require "./support/client_configs"
require "./support/fake_membership"
require "./support/fake_peer"

# Which client configurations apply to a peer (CA2, CF4, CD2) and what they
# allow it together (CA3, CF3, CF5, CD1), on a peer built by hand and groups
# whose members the spec names: the peer is in `staff`, not in `wheel`. The
# configurations that list signatures need Security and are integration
# tests.
describe TunnelgeistAuthorizer do
  {% if flag?(:darwin) %}
    include TunnelgeistClientConfigs
    include TunnelgeistFakePeer

    alias Authorizer = Tunnelgeist::Authorizer
    alias Config = Tunnelgeist::Config
    alias Reason = Tunnelgeist::Refusal::Reason

    def staff : Tunnelgeist::Membership
      TunnelgeistFakeMembership.new("staff", gid: 20_u32, members: [PEER_UID]).as(Tunnelgeist::Membership)
    end

    def wheel : Tunnelgeist::Membership
      TunnelgeistFakeMembership.new("wheel", gid: 0_u32, members: [0_u32]).as(Tunnelgeist::Membership)
    end

    def v4(address : String, *, bits : Int32, peer : String) : Tunnelgeist::Address
      Tunnelgeist::Address.new(Socket::IPAddress.new(address, 0), prefix: bits, peer: Socket::IPAddress.new(peer, 0))
    end

    def v6(address : String, *, bits : Int32) : Tunnelgeist::Address
      Tunnelgeist::Address.new(Socket::IPAddress.new(address, 0), prefix: bits)
    end

    def authorizer(clients : Array(Config::Client), *, membership : Tunnelgeist::Membership = staff) : Authorizer
      Authorizer.new(Config.new(socket: "/var/run/tg.sock", group: "tg", membership: membership, clients: clients))
    end

    def denial(kind : Authorizer::Denial::Kind, *, text : String) : Authorizer::Denial
      Authorizer::Denial.new(kind: kind, text: text)
    end

    # Admission

    test "admit refuses a peer outside the main group before any client configuration" do
      admission = authorizer([client("open")], membership: wheel).admit(fake_peer)

      assert(admission.group_refused?)
      assert(admission.refused?)
      assert(admission.clients.empty?)
      assert(admission.refusals.empty?)
      assert(admission.names.empty?)
    end

    test "admit applies a configuration without restrictions to every member of the main group" do
      admission = authorizer([client("open")]).admit(fake_peer)

      assert(!admission.group_refused?)
      assert(!admission.refused?)
      assert(admission.names == ["open"])
      assert(admission.refusals.empty?)
    end

    test "admit applies a configuration that lists the peer's uid and refuses one that does not" do
      admission = authorizer([client("other", users: [PEER_UID + 1]), client("mine", users: [PEER_UID])]).admit(fake_peer)

      assert(admission.names == ["mine"])
      assert(admission.refusals == [client_refusal("other", reason: Reason::Users)])
    end

    test "admit needs every kind a configuration lists and one entry of each kind" do
      admission = authorizer([
        client("both", users: [PEER_UID + 1, PEER_UID], groups: [wheel, staff]),
        client("group", users: [PEER_UID], groups: [wheel]),
        client("user", users: [PEER_UID + 1], groups: [staff]),
      ]).admit(fake_peer)

      assert(admission.names == ["both"])
      assert(admission.refusals == [
        client_refusal("group", reason: Reason::Groups),
        client_refusal("user", reason: Reason::Users),
      ])
    end

    test "admit refuses a member of the main group that no configuration applies to, naming each reason" do
      admission = authorizer([client("users", users: [PEER_UID + 1]), client("groups", groups: [wheel])]).admit(fake_peer)

      assert(admission.refused?)
      assert(!admission.group_refused?)
      assert(admission.names.empty?)
      assert(admission.refusals.map { |item| "#{item.name}=#{item.refusal}" } == ["users=users", "groups=groups"])
    end

    # What the applying configurations allow

    test "allow passes items each allowed by one of two configurations" do
      admission = applying([
        client("v4", addresses: [rule("10.0.0.0/8", peer: "10.0.0.0/8")], routes: ["10.0.0.0/8"]),
        client("v6", addresses: [rule("fd00::/8")], routes: ["fd00::/8"]),
      ])

      denied = admission.allow(addresses: [v4("10.1.2.3", bits: 24, peer: "10.1.2.1"), v6("fd00::1", bits: 64)],
        routes: [prefix("10.77.0.0/16"), prefix("fd00:1::/64")])

      assert(denied.nil?)
    end

    test "allow names the first denied address before any denied route" do
      admission = applying([client("v4", addresses: [rule("10.0.0.0/8", peer: "10.0.0.0/8")], routes: ["10.0.0.0/8"])])

      denied = admission.allow(
        addresses: [v4("10.1.2.3", bits: 24, peer: "10.1.2.1"), v4("192.168.1.1", bits: 24, peer: "192.168.1.2"),
                    v4("172.16.0.1", bits: 24, peer: "172.16.0.2")],
        routes: [prefix("172.16.0.0/12")])

      assert(denied == denial(:address, text: "192.168.1.1/24"))
      assert(denied.try(&.message) == "address 192.168.1.1/24 not allowed")
    end

    test "allow names the first denied route when every address is allowed" do
      admission = applying([client("v4", addresses: [rule("10.0.0.0/8", peer: "10.0.0.0/8")], routes: ["10.0.0.0/8"])])

      denied = admission.allow(addresses: [v4("10.1.2.3", bits: 24, peer: "10.1.2.1")],
        routes: [prefix("10.77.0.0/16"), prefix("172.16.0.0/12"), prefix("192.168.0.0/16")])

      assert(denied == denial(:route, text: "172.16.0.0/12"))
      assert(denied.try(&.message) == "route 172.16.0.0/12 not allowed")
    end

    test "allow denies an address or route with a shorter prefix than the rule's" do
      admission = applying([client("narrow", addresses: [rule("10.1.0.0/16", peer: "10.0.0.0/8")],
        routes: ["10.77.1.0/24"])])

      assert(admission.allow(addresses: [v4("10.1.2.3", bits: 16, peer: "10.1.2.1")], routes: [] of Tunnelgeist::Prefix).nil?)
      assert(admission.allow(addresses: [v4("10.1.2.3", bits: 8, peer: "10.1.2.1")], routes: [] of Tunnelgeist::Prefix) ==
             denial(:address, text: "10.1.2.3/8"))
      assert(admission.allow(addresses: [] of Tunnelgeist::Address, routes: [prefix("10.77.1.0/24")]).nil?)
      assert(admission.allow(addresses: [] of Tunnelgeist::Address, routes: [prefix("10.77.0.0/16")]) ==
             denial(:route, text: "10.77.0.0/16"))
    end

    test "allow denies an item of a family no configured rule has" do
      admission = applying([client("v4", addresses: [rule("0.0.0.0/0", peer: "0.0.0.0/0")], routes: ["0.0.0.0/0"])])

      assert(admission.allow(addresses: [] of Tunnelgeist::Address, routes: [prefix("fd00::/64")]) ==
             denial(:route, text: "fd00::/64"))
      assert(admission.allow(addresses: [v6("fd00::1", bits: 64)], routes: [] of Tunnelgeist::Prefix) ==
             denial(:address, text: "fd00::1/64"))
    end

    test "allow passes an empty request and denies any item when no configuration applies" do
      none = applying([] of Config::Client)

      assert(applying([client("bare")]).allow(addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix).nil?)
      assert(none.allow(addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix).nil?)
      assert(none.allow(addresses: [] of Tunnelgeist::Address, routes: [prefix("10.0.0.0/8")]) ==
             denial(:route, text: "10.0.0.0/8"))
      assert(none.allow(addresses: [v4("10.1.2.3", bits: 24, peer: "10.1.2.1")], routes: [] of Tunnelgeist::Prefix) ==
             denial(:address, text: "10.1.2.3/24"))
    end
  {% end %}
end
