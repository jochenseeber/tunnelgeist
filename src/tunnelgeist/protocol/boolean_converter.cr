{% skip_file unless flag?(:darwin) %}

require "json"
require "./error"

module Tunnelgeist
  module Protocol
    # :nodoc:
    # The `JSON::Field` converter that reads a `Bool` field and raises an
    # `Error` naming the field for any other value. It only reads: a
    # converter's `to_json` is never called for `false`, which
    # `JSON::Serializable` would write as null, so a type that writes a `Bool`
    # leaves it to the reader of `Bool` and checks it with
    # `Document::Outcome` before.
    struct BooleanConverter
      # The converter of the field *field*.
      def initialize(@field : String)
      end

      # The boolean *pull* is at.
      def from_json(pull : JSON::PullParser) : Bool
        raise Error.new("field #{@field} must be a boolean", field: @field) unless pull.kind.bool?
        pull.read_bool
      end
    end
  end
end
