{% skip_file unless flag?(:darwin) %}

require "json"

module Tunnelgeist
  struct Config
    module Document
      # A field the document type does not declare, raised by
      # `StrictFields` with the field's name.
      class UnknownField < JSON::ParseException
        # The name of the field.
        getter key : String

        # The error about the field *key* at *line* and *column*.
        def initialize(@key : String, *, line : Int64, column : Int64)
          super("unknown field #{@key.inspect}", line, column)
        end
      end
    end
  end
end
