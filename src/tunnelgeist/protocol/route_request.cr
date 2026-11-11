{% skip_file unless flag?(:darwin) %}

require "json"
require "../interface_name"
require "../key"
require "../prefix"
require "./common"
require "./device_request"
require "./text_converter"

module Tunnelgeist
  module Protocol
    # What the requests that add or remove one route of a device share: the
    # prefix and, from `DeviceRequest`, the device and its key. The daemon
    # replies ok, or an error when the key is wrong or the change is refused.
    abstract struct RouteRequest < DeviceRequest
      # The route to add or remove; its host bits are zero.
      @[JSON::Field(converter: Tunnelgeist::Protocol::TextConverter(Tunnelgeist::Prefix).new("route"))]
      getter route : Prefix

      # Built by the client; the daemon reads it with `Request.parse`.
      def initialize(*, @name : InterfaceName, @key : Key, @route : Prefix)
        @version = VERSION
        @operation = self.class.operation
      end

      def_equals name, key, route

      protected def inspect_subject(io : IO) : Nil
        io << "route=" << @route
      end
    end
  end
end
