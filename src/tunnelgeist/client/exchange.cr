{% skip_file unless flag?(:darwin) %}

require "../protocol/reply"

class Tunnelgeist::Client
  # The ok reply of the daemon and the descriptor that came with it, if any.
  private record Exchange, reply : Protocol::Reply, fd : Int32? do
    # The descriptor; raises when none came with the reply.
    def fd! : Int32
      fd || raise NilAssertionError.new("no descriptor came with the reply")
    end
  end
end
