{% skip_file unless flag?(:darwin) %}

require "json"
require "./error"

module Tunnelgeist
  module Protocol
    # :nodoc:
    # The check of a message line before it is read into its type: the
    # syntax, as a whole, and that no object holds a key twice.
    #
    # The syntax comes first because the reader of a type looks one token
    # ahead, so it would blame a syntax error on the field before it, and it
    # ignores what follows the value. A key given twice would let a later
    # value override an earlier one the reader has already checked, or keep
    # the earlier one where `JSON::Serializable` skips a null, so it is
    # refused.
    module SyntaxCheck
      # Raises `Error` for malformed JSON in *line* or a key an object holds
      # twice. The error about malformed JSON names only the position: the
      # parser's own message quotes the unexpected token, an arbitrary piece
      # of client text no check has passed, which has no place in the log
      # and the reply.
      def self.check(line : String) : Nil
        pull = JSON::PullParser.new(line)
        walk(pull)
        pull.raise("Unexpected content after the JSON value") unless pull.kind.eof?
      rescue error : JSON::ParseException
        raise Error.new("malformed JSON at line #{error.line_number}, column #{error.column_number}")
      end

      # Reads the value *pull* is at with everything it holds.
      private def self.walk(pull : JSON::PullParser) : Nil
        case pull.kind
        when .begin_object?
          keys = Set(String).new
          pull.read_object do |key|
            raise Error.new("duplicate field #{key.inspect}", field: key) unless keys.add?(key)
            walk(pull)
          end
        when .begin_array?
          pull.read_array { walk(pull) }
        when .int?, .float?
          read_number(pull)
        when .eof?
          pull.raise("Unexpected end of input")
        else
          # `read_next`, not `skip`: after `skip` of a scalar the pull parser
          # can report the next object's first key as the last string it
          # read.
          pull.read_next
        end
      end

      # Converts the number *pull* is at rather than skipping it, so that a
      # number out of range is malformed here as it is for `JSON.parse`, and
      # at its first character, where `JSON.parse` puts it: the lexer reports
      # the character after it.
      private def self.read_number(pull : JSON::PullParser) : Nil
        line, column = pull.location
        begin
          pull.kind.int? ? pull.read_int : pull.read_float
        rescue JSON::ParseException
          raise JSON::ParseException.new("Invalid number", line, column)
        end
      end
    end
  end
end
