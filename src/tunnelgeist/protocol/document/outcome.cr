{% skip_file unless flag?(:darwin) %}

require "json"
require "../boolean_converter"

module Tunnelgeist
  module Protocol
    module Document
      # :nodoc:
      # The `ok` of a reply, read before the reply: `Reply` reads `ok` with
      # the reader of `Bool`, whose error does not name the field (see
      # `BooleanConverter`). The other fields are skipped.
      struct Outcome
        include JSON::Serializable

        # Whether the request succeeded.
        @[JSON::Field(converter: Tunnelgeist::Protocol::BooleanConverter.new("ok"))]
        getter? ok : Bool
      end
    end
  end
end
