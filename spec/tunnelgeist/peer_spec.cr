require "../spec_helper"
require "../../src/tunnelgeist/peer"

# The identity of a connected peer from its audit token (UA8).
describe TunnelgeistPeer do
  {% if flag?(:darwin) %}
    test "Peer.of on a closed socket raises" do
      left, right = UNIXSocket.pair
      right.close
      left.close

      raised(IO::Error) { Tunnelgeist::Peer.of(left) }
    end
  {% end %}
end
