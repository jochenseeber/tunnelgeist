{% skip_file unless flag?(:darwin) %}

require "json"
require "./error"
require "./field_path"
require "./location"

module Tunnelgeist
  struct Config
    # The check of a configuration file's JSON before it is read into its
    # `Document` type: the syntax, as a whole, and that no object holds a
    # key twice.
    #
    # The syntax comes first because the reader of a document looks one
    # token ahead, so it would blame a syntax error on the field before it.
    # A key given twice would let a later value, even a null, override an
    # earlier one where a reader of the file expects the first, or keep the
    # earlier one where `JSON::Serializable` skips a null, so it is refused.
    module SyntaxCheck
      # Raises `Config::Error` about *file* for malformed JSON in *text* or
      # a key an object holds twice.
      def self.check(text : String, *, file : String) : Nil
        pull = JSON::PullParser.new(text)
        walk(pull, file: file, at: nil)
        pull.raise("Unexpected content after the JSON value") unless pull.kind.eof?
      rescue error : JSON::ParseException
        # The whole text, with its control characters escaped: the lexer
        # quotes the character it stopped at, which may be a newline.
        reason = error.message.to_s.rchop(" at line #{error.line_number}, column #{error.column_number}").inspect_unquoted
        raise Error.new("malformed JSON: #{reason}", file: file, location: Location.of(error), cause: error)
      end

      # Reads the value *pull* is at, the field at the path *at*, with
      # everything it holds.
      private def self.walk(pull : JSON::PullParser, *, file : String, at : String?) : Nil
        case pull.kind
        when .begin_object?
          keys = Set(String).new
          pull.read_object do |key, key_location|
            field = FieldPath.child(at, key)
            unless keys.add?(key)
              line, column = key_location
              raise Error.new("duplicate field #{key.inspect}", file: file, field: field,
                location: Location.new(line: line, column: column))
            end
            walk(pull, file: file, at: field)
          end
        when .begin_array?
          index = 0
          pull.read_array do
            walk(pull, file: file, at: FieldPath.element(at, index))
            index += 1
          end
        when .eof?
          pull.raise("Unexpected end of input")
        else
          # `read_next`, not `skip`: after `skip` of a scalar the pull parser
          # can report the next object's first key as the last string it
          # read.
          pull.read_next
        end
      end
    end
  end
end
