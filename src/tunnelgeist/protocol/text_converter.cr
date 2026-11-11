{% skip_file unless flag?(:darwin) %}

require "json"
require "../interface_name"
require "../prefix"
require "./common"
require "./error"
require "./operation"

module Tunnelgeist
  module Protocol
    # :nodoc:
    # The `JSON::Field` converter of a field the wire carries as a string: a
    # `String`, or an `InterfaceName`, a route `Prefix` or an
    # `Operation` parsed from it. Every error is an `Error` about the field.
    struct TextConverter(T)
      # The converter of the field *field*. *nullable* says whether the field
      # may be null, for the error text only: `JSON::Serializable` reads a null
      # of a nilable field itself. *subject* is what the error about a value
      # that is not a string calls it: the field, or `"route"` for an element
      # of `routes`.
      def initialize(@field : String, *, @nullable : Bool = false, @subject : String = "field #{field}")
      end

      # The value of the string *pull* is at.
      def from_json(pull : JSON::PullParser) : T
        unless pull.kind.string?
          raise Error.new("#{@subject} must be a string#{" or null" if @nullable}", field: @field)
        end
        decode(pull.read_string, type: T)
      end

      # Writes *value* as its wire text; the converter protocol of
      # `JSON::Field` passes both positionally.
      def to_json(value : T, json : JSON::Builder) : Nil
        json.string(encode(value))
      end

      private def decode(text : String, *, type _type : String.class) : String
        text
      end

      private def decode(text : String, *, type _type : InterfaceName.class) : InterfaceName
        Protocol.parse_name(text)
      end

      private def decode(text : String, *, type _type : Prefix.class) : Prefix
        Protocol.parse_route(text, field: @field)
      end

      # `Operation.parse?` would also accept `"Create"` and `"addaddress"`,
      # which the protocol rejects.
      private def decode(text : String, *, type _type : Operation.class) : Operation
        Operation.from_wire?(text) || raise Error.new("unknown op #{text.inspect}", field: @field)
      end

      private def encode(value : Operation) : String
        value.wire
      end

      private def encode(value : String | InterfaceName | Prefix) : String
        value.to_s
      end
    end
  end
end
