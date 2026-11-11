{% skip_file unless flag?(:darwin) %}

require "json"
require "../operation"
require "../text_converter"

module Tunnelgeist
  module Protocol
    module Document
      # :nodoc:
      # The `op` of a request, read after its version and before the request,
      # whose type it selects. The other fields are skipped.
      struct Op
        include JSON::Serializable

        # The operation the request asks for.
        @[JSON::Field(converter: Tunnelgeist::Protocol::TextConverter(Tunnelgeist::Protocol::Operation).new("op"))]
        getter op : Operation
      end
    end
  end
end
