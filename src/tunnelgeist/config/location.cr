{% skip_file unless flag?(:darwin) %}

require "json"

module Tunnelgeist
  struct Config
    # A place in a configuration file, as the JSON reader reports it: the
    # line and the column, both counted from 1.
    record Location, line : Int32, column : Int32 do
      # The place *error* names.
      def self.of(error : JSON::ParseException) : Location
        new(line: error.line_number, column: error.column_number)
      end

      # The place of the first character of *text* that is not JSON
      # whitespace, where the value it holds begins.
      def self.start_of(text : String) : Location
        line = 1
        column = 1
        text.each_char do |char|
          case char
          when '\n'
            line += 1
            column = 1
          when ' ', '\t', '\r'
            column += 1
          else
            break
          end
        end
        new(line: line, column: column)
      end

      # `LINE:COLUMN`, as it follows the file name in an error message.
      def to_s(io : IO) : Nil
        io << line << ':' << column
      end
    end
  end
end
