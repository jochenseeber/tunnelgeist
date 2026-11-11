{% skip_file unless flag?(:darwin) %}

require "json"
require "./strict_fields"
require "./text_converter"

module Tunnelgeist
  struct Config
    module Document
      # An address rule as the file has it (CF3): two prefixes in CIDR
      # notation, the peer optional.
      struct AddressRule
        include JSON::Serializable
        include JSON::Serializable::Strict
        include StrictFields

        # The network a requested address must lie in.
        @[JSON::Field(converter: TextConverter.new)]
        getter network : String
        # The prefix the peer of an IPv4 address must lie in; nil when the
        # rule has none.
        @[JSON::Field(converter: TextConverter.new(nullable: true))]
        getter peer : String?

        # The peer prefix; raises `NilAssertionError` for a rule without one.
        def peer! : String
          peer || raise NilAssertionError.new("the rule for #{network} has no peer")
        end
      end
    end
  end
end
