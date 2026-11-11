{% skip_file unless flag?(:darwin) %}

require "json"
require "../interface_name"
require "./common"
require "./document/op"
require "./document/version"
require "./error"
require "./integer_converter"
require "./operation"
require "./strict_fields"
require "./syntax_check"
require "./text_converter"

module Tunnelgeist
  module Protocol
    # A request of a client, read and written with `JSON::Serializable`.
    # `parse` reads a request of any type and `from_json` of a request type
    # one of that type; both raise nothing but `Error` and are the readers
    # for untrusted input. The constructor from a `JSON::PullParser` that
    # `JSON::Serializable` adds is not: it skips the checks of the whole
    # line, and its errors can quote the line.
    abstract struct Request
      include JSON::Serializable
      include StrictFields

      # The protocol version; `VERSION` in every request a reader accepts.
      @[JSON::Field(converter: Tunnelgeist::Protocol::IntegerConverter.new("version"))]
      getter version : Int32
      # The operation the request asks for: `parse` picks the request type by
      # it, and it is the `op` written on the wire and logged. Each request
      # type names its own as the class method `operation`, and its
      # initializer sets both fields.
      @[JSON::Field(key: "op", converter: Tunnelgeist::Protocol::TextConverter(Tunnelgeist::Protocol::Operation).new("op"))]
      getter operation : Operation

      # Parses one line of JSON. Raises `Error`, and nothing else, for
      # anything that is not a valid request. The version is read first and
      # the op second, each on its own, so that a request of another version
      # gets "unsupported version" whatever else it holds.
      def self.parse(line : String) : Request
        check(line)
        version = read(Document::Version, line: line).version
        raise Error.new("unsupported version #{version}", field: "version") unless version == VERSION

        case read(Document::Op, line: line).op
        in .create?
          read(Create, line: line)
        in .add_address?
          read(AddAddress, line: line)
        in .remove_address?
          read(RemoveAddress, line: line)
        in .add_route?
          read(AddRoute, line: line)
        in .remove_route?
          read(RemoveRoute, line: line)
        end
      end

      # Parses one line of JSON as a request of this type, which must be a
      # concrete one such as `Create`. Raises `Error`, and nothing else, for
      # anything that is not a valid request of this type.
      def self.from_json(string : String) : self
        check(string)
        read(self, line: string)
      end

      # Reads one request from *io* up to its end, as `from_json` of a
      # string does; reads at most one byte over `MAX_REQUEST`.
      def self.from_json(io : IO) : self
        from_json(Protocol.read_limited(io, limit: MAX_REQUEST))
      end

      # Refuses to read a request from the member *root* of an object: a
      # request is the whole line. The overload `JSON::Serializable` would
      # inherit skips the checks of the line and its errors can quote it.
      def self.from_json(string_or_io : String | IO, root : String) : self
        raise Error.new("a request is read from the whole line, not from a root member")
      end

      # The checks of the whole line, before any field is read. The length
      # comes first, so that a line `from_json` of an `IO` cut inside a
      # character gets the same error as through `parse`. The encoding comes
      # before the syntax, so that a line that is not UTF-8 gets the error
      # that says so and not one about a field.
      private def self.check(line : String) : Nil
        raise Error.new("request longer than #{MAX_REQUEST} bytes") if line.bytesize > MAX_REQUEST
        raise Error.new("request is not valid UTF-8") unless line.valid_encoding?

        SyntaxCheck.check(line)
      end

      private def self.read(type : T.class, *, line : String) : T forall T
        Protocol.read(type, pull: JSON::PullParser.new(line), what: "request")
      end

      # The device the request is about; nil when a create request leaves
      # the choice to the daemon.
      abstract def name : InterfaceName?

      # Checks what `parse` checks before it picks the type, for a request
      # that `from_json` of its type reads.
      protected def after_initialize : Nil
        raise Error.new("unsupported version #{@version}", field: "version") unless @version == VERSION

        expected = self.class.operation
        return if @operation == expected
        raise Error.new("op #{@operation.wire.inspect} is not #{expected.wire.inspect}", field: "op")
      end
    end
  end
end
