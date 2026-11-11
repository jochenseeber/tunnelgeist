{% skip_file unless flag?(:darwin) %}

require "json"
require "./error"

module Tunnelgeist
  module Protocol
    # :nodoc:
    # The `JSON::Field` converter of an `Int32` field. It raises an `Error`
    # naming the field for any other value, a float, a number outside `Int32`
    # and null included, where the reader of `Int32` would raise a
    # `JSON::ParseException` that does not.
    struct IntegerConverter
      # The converter of the field *field*.
      def initialize(@field : String)
      end

      # The integer *pull* is at.
      def from_json(pull : JSON::PullParser) : Int32
        if pull.kind.int?
          value = pull.read_int
          if Int32::MIN <= value <= Int32::MAX
            number = value.to_i32
            return number
          end
        end
        raise Error.new("field #{@field} must be an integer", field: @field)
      end

      # Writes *value*; the converter protocol of `JSON::Field` passes both
      # positionally.
      def to_json(value : Int32, json : JSON::Builder) : Nil
        json.number(value)
      end
    end
  end
end
