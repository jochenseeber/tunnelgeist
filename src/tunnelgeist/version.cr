module Tunnelgeist
  # The version of tunnelgeist, read from `shard.yml` when compiling.
  VERSION = {{ `shards version "#{__DIR__}/../.."`.stringify.chomp }}
end
