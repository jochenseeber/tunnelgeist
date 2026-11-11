require "../../../src/tunnelgeist/membership"
require "../../../src/tunnelgeist/peer"

{% if flag?(:darwin) %}
  # A `Membership` that asks no directory service: the spec names the group,
  # its gid and the uids of its members.
  class TunnelgeistFakeMembership < Tunnelgeist::Membership
    def initialize(@name : String, *, @gid : UInt32, members : Array(UInt32))
      @members = members
    end

    # Whether *peer*'s uid is one of the members.
    def member?(peer : Tunnelgeist::Peer) : Bool
      @members.includes?(peer.uid)
    end
  end
{% end %}
