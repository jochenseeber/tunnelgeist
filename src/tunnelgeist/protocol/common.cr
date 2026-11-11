{% skip_file unless flag?(:darwin) %}

require "json"
require "../device"
require "../interface_name"
require "../prefix"
require "./error"

module Tunnelgeist
  module Protocol
    # The protocol version every request carries.
    VERSION = 1
    # The most bytes of one request line.
    MAX_REQUEST = 65_536
    # The most bytes of one reply line, as many as of a request.
    MAX_REPLY = 65_536
    # How long the daemon waits for a whole request line.
    REQUEST_TIMEOUT = 5.seconds
    # The MTU of a created device, and the least a request may ask for.
    DEFAULT_MTU = Device::DEFAULT_MTU
    # The MTUs a create request may ask for.
    MTU_RANGE = DEFAULT_MTU..65_535
    # The most addresses a create request may carry.
    MAX_ADDRESSES = 16
    # The most routes a create request may carry.
    MAX_ROUTES = 64
    # The error text for a device the daemon does not know: one it did not
    # create, or one that is gone.
    UNKNOWN_DEVICE = "unknown device"

    # The socket the daemon listens on and the client connects to unless told
    # otherwise.
    DEFAULT_SOCKET = "/var/run/tunnelgeist.sock"

    # :nodoc:
    # The text of *io* up to its end, but at most one byte over *limit*:
    # enough for the reader to tell a message at the limit from a longer
    # one without holding all of a longer one.
    def self.read_limited(io : IO, *, limit : Int32) : String
      String.build do |buffer|
        IO.copy(io, buffer, limit + 1)
      end
    end

    # :nodoc:
    # Reads the object *pull* is at, whose syntax `SyntaxCheck` has passed,
    # as *type*, a `JSON::Serializable` type whose fields have the protocol's
    # converters or were checked before. *what* names the object in the
    # error when it is not an object. Raises `Error`, and nothing else: the
    # converters and `StrictFields` raise it themselves, and the one error
    # left to the reader of *type*, a missing field, is turned into one here.
    def self.read(type : T.class, *, pull : JSON::PullParser, what : String) : T forall T
      raise Error.new("#{what} must be a JSON object") unless pull.kind.begin_object?
      type.new(pull)
    rescue error : JSON::ParseException
      attribute = error.as?(JSON::SerializableError).try(&.attribute)
      raise Error.new("missing field #{attribute}", field: attribute, cause: error) if attribute && error.cause.nil?
      # Not reached while every field has a converter or was checked before.
      # The message of the reader is left out, as `SyntaxCheck` leaves out
      # the parser's.
      raise Error.new("invalid #{what}", cause: error)
    end

    # Parses the device name *text*, `utunN`.
    def self.parse_name(text : String) : InterfaceName
      InterfaceName.parse?(text) || raise Error.new("invalid device name #{text.inspect}", field: "name")
    end

    # Parses a route, which must have no host bits set (UP4).
    def self.parse_route(text : String, *, field : String) : Prefix
      prefix = begin
        Prefix.parse(text)
      rescue Prefix::ParseError
        raise Error.new("invalid route #{text.inspect}", field: field)
      end
      raise Error.new("route #{text} has host bits set", field: field) if prefix.host_bits?
      prefix
    end
  end
end
