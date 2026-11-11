{% skip_file unless flag?(:darwin) %}

class Tunnelgeist::Client
  # The first line of a reply and the descriptor that came with its first
  # segment, if any.
  private record ReplyLine, line : String, fd : Int32? do
    # The descriptor; raises when none came with the line.
    def fd! : Int32
      fd || raise NilAssertionError.new("no descriptor came with the reply")
    end
  end
end
