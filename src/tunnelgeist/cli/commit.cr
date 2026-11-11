module Tunnelgeist
  module CLI
    # The abbreviated hash of the commit the program was built from, read
    # from git when compiling; "unknown" when the sources are not a git
    # checkout of their own, so a copy inside another repository never
    # reports that repository's commit.
    COMMIT = {{ `cd "#{__DIR__}/../../.." && test -e .git && git rev-parse --short HEAD || echo unknown`.stringify.strip }}
  end
end
