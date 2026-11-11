{% skip_file unless flag?(:darwin) %}

require "socket"

module Tunnelgeist
  module CLI
    # The socket `serve` listens on, and its path, which a reload of the
    # configuration cannot change (CN4).
    record Listener, server : UNIXServer, path : String
  end
end
