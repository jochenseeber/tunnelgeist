require "socket"
require "../../../src/tunnelgeist/peer"

# The peer checks' integration tests run them on this process itself.
module TunnelgeistOwnPeer
  # Runs the block with the peer read from one end of a socket pair, which is
  # this process itself.
  def with_own_peer(&)
    left, right = UNIXSocket.pair
    begin
      yield Tunnelgeist::Peer.of(left)
    ensure
      left.close
      right.close
    end
  end
end
