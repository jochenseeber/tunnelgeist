{% skip_file unless flag?(:darwin) %}

require "./refusal"

module Tunnelgeist
  abstract class CheckedDirectory
    # A directory or file a `CheckedDirectory` was asked to open does not
    # exist; `path` is the path up to it. A glob include takes a missing
    # directory as matching nothing, and `install` creates a missing
    # directory, so both tell this apart from the other refusals.
    class Missing < Refusal
      # A refusal of the missing *path*.
      def initialize(*, path : String)
        super("does not exist", path: path)
      end
    end
  end
end
