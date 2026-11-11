require "../../../src/tunnelgeist/lib_system"
require "../../../src/tunnelgeist/peer"

# Peers built by hand, so a spec decides the uid a check sees instead of
# reading this process's own.
module TunnelgeistFakePeer
  {% if flag?(:darwin) %}
    extend self

    # The uid of the peer `fake_peer` builds unless told otherwise.
    PEER_UID = 501_u32

    # A peer with *uid*, *gid* and *pid* and an empty audit token, which no
    # check that uses a fake peer reads.
    def fake_peer(*, uid : UInt32 = PEER_UID, gid : UInt32 = 20_u32, pid : Int32 = 4_242) : Tunnelgeist::Peer
      Tunnelgeist::Peer.new(uid: uid, gid: gid, pid: pid, token: Tunnelgeist::LibSystem::AuditToken.new)
    end
  {% end %}
end
