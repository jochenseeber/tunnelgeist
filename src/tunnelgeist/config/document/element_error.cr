{% skip_file unless flag?(:darwin) %}

require "json"

module Tunnelgeist
  struct Config
    module Document
      # An error in the element at `index` of a JSON array, which is the
      # cause. `JSON::Serializable` names the field of each object an error
      # is in, but not the element of an array, so `Elements` adds it and the
      # loader can name the whole field path.
      class ElementError < JSON::ParseException
        # The index of the element the cause is about.
        getter index : Int32

        # The error *cause* about the element at *index*, at its location.
        def initialize(@index : Int32, *, cause : JSON::ParseException)
          super("#{cause.message}\n  parsing element #{@index}", cause.line_number, cause.column_number, cause)
        end
      end
    end
  end
end
