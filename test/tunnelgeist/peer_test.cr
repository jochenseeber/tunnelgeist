require "../test_helper"
require "../../src/tunnelgeist/lib_system"
require "../../src/tunnelgeist/peer"
require "./support/own_peer"

# The identity of a connected peer from its audit token (UA8), read of this
# process and compared with its own effective uid and gid.
describe TunnelgeistPeer do
  {% if flag?(:darwin) %}
    include TunnelgeistOwnPeer

    test "Peer.of reads this process's effective uid, gid and pid from the audit token" do
      uid = Tunnelgeist::LibSystem.geteuid
      gid = Tunnelgeist::LibSystem.getegid
      pid = Process.pid

      with_own_peer do |peer|
        assert(peer.uid == uid)
        assert(peer.gid == gid)
        assert(peer.pid == pid)
      end
    end
  {% end %}
end
