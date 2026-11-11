{% skip_file unless flag?(:darwin) %}

require "json"
require "./error"

module Tunnelgeist
  module Protocol
    # :nodoc:
    # The `JSON::Field` converter of an array field with at most `limit`
    # elements, each read and written by the converter *element*.
    struct ListConverter(C)
      # The converter of the field *field*, which holds at most *limit*
      # elements that *element* converts.
      def initialize(@field : String, *, @limit : Int32, @element : C)
      end

      # The elements of the array *pull* is at. Raises `Error` when it is not
      # an array or longer than the limit. The length is checked before any
      # element is converted, so an oversized list gets the length error
      # whatever its elements hold: the elements are kept as raw JSON until
      # then, and those past the limit are counted, not kept.
      def from_json(pull : JSON::PullParser)
        raise Error.new("field #{@field} must be an array", field: @field) unless pull.kind.begin_array?

        raw = [] of String
        count = 0
        pull.read_array do
          count += 1
          if count > @limit
            pull.skip
          else
            raw << raw_element(pull)
          end
        end
        raise Error.new("too many #{@field}: #{count}, at most #{@limit}", field: @field) if count > @limit

        raw.map { |element| @element.from_json(JSON::PullParser.new(element)) }
      end

      # The raw JSON of the element *pull* is at. The builder may nest as deep
      # as the parser: the default of a builder is lower, and `read_raw`
      # would raise `JSON::Error` for an element the parser accepted.
      private def raw_element(pull : JSON::PullParser) : String
        String.build do |io|
          json = JSON::Builder.new(io)
          json.max_nesting = pull.max_nesting
          json.document { pull.read_raw(json) }
        end
      end

      # Writes *value*; the converter protocol of `JSON::Field` passes both
      # positionally.
      def to_json(value : Array, json : JSON::Builder) : Nil
        json.array do
          value.each { |element| @element.to_json(element, json) }
        end
      end
    end
  end
end
