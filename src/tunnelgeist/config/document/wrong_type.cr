{% skip_file unless flag?(:darwin) %}

require "json"
require "./value_type"

module Tunnelgeist
  struct Config
    module Document
      # A value of another JSON type than the field takes, raised by the
      # converters before they read it, so the error names the type the
      # file should hold and not the reader's token kinds.
      class WrongType < JSON::ParseException
        # The type the field takes.
        getter expected : ValueType
        # Whether the field also takes null.
        getter? nullable : Bool

        # The error about the value *pull* is at, which is not of the type
        # *expected* (or null, when *nullable*).
        def initialize(@expected : ValueType, *, @nullable : Bool = false, pull : JSON::PullParser)
          super(reason, pull.line_number, pull.column_number)
        end

        # The error about a value at *line* and *column*, which is not of the
        # type *expected* (or null, when *nullable*).
        def initialize(@expected : ValueType, *, @nullable : Bool = false, line : Int32, column : Int32)
          super(reason, line, column)
        end

        # Why the value is refused, such as `must be a string or null`.
        def reason : String
          "must be #{@expected.phrase}#{" or null" if @nullable}"
        end
      end
    end
  end
end
