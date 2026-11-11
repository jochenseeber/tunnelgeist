{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  struct Config
    # The text of a configuration file `TrustedDirectory` read, with the
    # path it walked to it.
    record TrustedFile, path : String, text : String
  end
end
