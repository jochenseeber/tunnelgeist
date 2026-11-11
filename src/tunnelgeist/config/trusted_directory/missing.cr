{% skip_file unless flag?(:darwin) %}

require "../error"

module Tunnelgeist
  struct Config
    class TrustedDirectory
      # A directory or file `TrustedDirectory` was asked to open does not
      # exist; `file` is the path walked up to it. A glob include takes a
      # missing directory as matching nothing, so the loader tells this
      # apart from the other refusals.
      class Missing < Error
        # An error about the missing *file*.
        def initialize(*, file : String)
          super("does not exist", file: file)
        end
      end
    end
  end
end
