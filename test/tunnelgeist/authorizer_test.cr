require "socket"
require "../test_helper"
require "../../src/tunnelgeist/authorizer"
require "../../src/tunnelgeist/membership"
require "../../spec/tunnelgeist/support/client_configs"
require "./support/own_peer"

# Which client configurations apply to this process (CA2, CF4, CD2) with the
# system's groups and Security: every macOS user is in `staff`, nobody but
# root in `wheel`, and the test binary is ad-hoc signed without the hardened
# runtime.
describe TunnelgeistAuthorizer do
  {% if flag?(:darwin) %}
    include TunnelgeistClientConfigs
    include TunnelgeistOwnPeer

    alias Authorizer = Tunnelgeist::Authorizer
    alias Config = Tunnelgeist::Config
    alias Reason = Tunnelgeist::Refusal::Reason

    # A requirement no process of this suite meets.
    UNMET_REQUIREMENT = %(identifier "io.github.jochenseeber.tunnelgeist.nobody")

    def staff : Tunnelgeist::Membership
      Tunnelgeist::Membership.new("staff")
    end

    def wheel : Tunnelgeist::Membership
      Tunnelgeist::Membership.new("wheel")
    end

    def authorizer(clients : Array(Config::Client), *, membership : Tunnelgeist::Membership = staff) : Authorizer
      Authorizer.new(Config.new(socket: "/var/run/tg.sock", group: "tg", membership: membership, clients: clients))
    end

    test "admit needs every kind a configuration lists, with the system's groups and Security" do
      admission = with_own_peer do |peer|
        authorizer([
          client("both", users: [peer.uid + 1, peer.uid], groups: [wheel, staff]),
          client("group", users: [peer.uid], groups: [wheel]),
          client("signature", users: [peer.uid], groups: [staff], signatures: [UNMET_REQUIREMENT]),
          client("user", users: [peer.uid + 1], groups: [staff]),
        ]).admit(peer)
      end

      assert(admission.names == ["both"])
      assert(admission.refusals == [
        client_refusal("group", reason: Reason::Groups),
        client_refusal("signature", reason: Reason::Requirement),
        client_refusal("user", reason: Reason::Users),
      ])
    end

    test "admit tells no signatures, an empty signatures list and an unmet requirement apart" do
      admission = with_own_peer do |peer|
        authorizer([
          client("unsigned"),
          client("empty", signatures: [] of String),
          client("unmet", signatures: [UNMET_REQUIREMENT]),
          client("met", signatures: ["always"]),
        ]).admit(peer)
      end

      assert(admission.names == ["unsigned"])
      assert(admission.refusals == [
        client_refusal("empty", reason: Reason::Requirement),
        client_refusal("unmet", reason: Reason::Requirement),
        client_refusal("met", reason: Reason::HardenedRuntime),
      ])
    end
  {% end %}
end
