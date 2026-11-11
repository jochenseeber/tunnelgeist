{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  class Authorizer
    struct Denial
      # What kind of request item a client configuration did not allow.
      enum Kind
        # A local address with its prefix length.
        Address
        # A route destination prefix.
        Route
      end
    end
  end
end
