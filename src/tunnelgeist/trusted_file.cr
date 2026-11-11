{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  # The text of a file a `CheckedDirectory` read, with the path it walked
  # to it.
  record TrustedFile, path : String, text : String
end
