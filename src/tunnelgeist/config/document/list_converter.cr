{% skip_file unless flag?(:darwin) %}

require "json"
require "./element_error"
require "./value_type"
require "./wrong_type"

module Tunnelgeist
  struct Config
    module Document
      # The `JSON::Field` converter of an array whose elements the converter
      # *element* reads. An element that cannot be read raises an
      # `ElementError` naming its index.
      struct ListConverter(C)
        # The converter of an array of what *element* reads.
        def initialize(@element : C)
        end

        # The elements of the array *pull* is at; raises `WrongType` when it
        # is at anything else.
        def from_json(pull : JSON::PullParser)
          raise WrongType.new(ValueType::Array, pull: pull) unless pull.kind.begin_array?

          elements = [] of typeof(@element.from_json(pull))
          pull.read_array do
            elements << @element.from_json(pull)
          rescue error : JSON::ParseException
            raise ElementError.new(elements.size, cause: error)
          end
          elements
        end
      end
    end
  end
end
