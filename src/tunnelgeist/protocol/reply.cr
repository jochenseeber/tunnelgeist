{% skip_file unless flag?(:darwin) %}

require "json"
require "../interface_name"
require "./common"
require "./document/outcome"
require "./error"
require "./strict_fields"
require "./syntax_check"
require "./text_converter"

module Tunnelgeist
  module Protocol
    # The reply of the daemon: `{"ok": true, …}` or
    # `{"ok": false, "error": "MESSAGE"}`, read and written with
    # `JSON::Serializable`. Fields that are nil are left out.
    record Reply, ok : Bool, name : InterfaceName? = nil, error : String? = nil do
      include JSON::Serializable
      include StrictFields

      # `ok` has no converter, which `JSON::Serializable` would not call for
      # `false`; `parse` checks it with `Document::Outcome` first.
      @[JSON::Field(converter: Tunnelgeist::Protocol::TextConverter(Tunnelgeist::InterfaceName).new("name", nullable: true))]
      @name : InterfaceName?
      @[JSON::Field(converter: Tunnelgeist::Protocol::TextConverter(String).new("error", nullable: true))]
      @error : String?

      # Raises `Error`, and nothing else, when *line* is not a valid reply.
      def self.parse(line : String) : Reply
        from_json(line)
      end

      # Same as `parse`. The constructor from a `JSON::PullParser` that
      # `JSON::Serializable` adds skips the checks of the whole line, and its
      # errors can quote the line.
      def self.from_json(string : String) : Reply
        raise Error.new("reply longer than #{MAX_REPLY} bytes") if string.bytesize > MAX_REPLY
        # Before the syntax, so that a reply that is not UTF-8 gets the error
        # that says so and not one about a field.
        raise Error.new("reply is not valid UTF-8") unless string.valid_encoding?
        SyntaxCheck.check(string)
        Protocol.read(Document::Outcome, pull: JSON::PullParser.new(string), what: "reply")
        Protocol.read(Reply, pull: JSON::PullParser.new(string), what: "reply")
      end

      # Reads one reply from *io* up to its end, as `parse` does; reads at
      # most one byte over `MAX_REPLY`.
      def self.from_json(io : IO) : Reply
        from_json(Protocol.read_limited(io, limit: MAX_REPLY))
      end

      # Refuses to read a reply from the member *root* of an object: a reply
      # is the whole line. The overload `JSON::Serializable` would inherit
      # skips the checks of the line and its errors can quote it.
      def self.from_json(string_or_io : String | IO, root : String) : Reply
        raise Error.new("a reply is read from the whole line, not from a root member")
      end

      # The device name; raises `NilAssertionError` when the reply has none.
      def name! : InterfaceName
        @name || raise NilAssertionError.new("the reply has no name")
      end

      # The error message; raises `NilAssertionError` when the reply has none.
      def error! : String
        @error || raise NilAssertionError.new("the reply has no error")
      end
    end
  end
end
