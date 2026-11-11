{% skip_file unless flag?(:darwin) %}

require "json"
require "../integer_converter"

module Tunnelgeist
  module Protocol
    module Document
      # :nodoc:
      # The `version` of a request, read before anything else: the other
      # fields are skipped, whatever they hold, since another version may
      # define them differently.
      struct Version
        include JSON::Serializable

        # The protocol version the request was written for.
        @[JSON::Field(converter: Tunnelgeist::Protocol::IntegerConverter.new("version"))]
        getter version : Int32
      end
    end
  end
end
