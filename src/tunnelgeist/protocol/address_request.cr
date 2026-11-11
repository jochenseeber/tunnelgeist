{% skip_file unless flag?(:darwin) %}

require "json"
require "../address"
require "../interface_name"
require "../key"
require "./address_converter"
require "./common"
require "./device_request"

module Tunnelgeist
  module Protocol
    # What the requests that add or remove one address of a device share: the
    # address and, from `DeviceRequest`, the device and its key. The daemon
    # replies ok, or an error when the key is wrong or the change is refused.
    abstract struct AddressRequest < DeviceRequest
      # The address to add or remove; it carries its own prefix length and peer.
      @[JSON::Field(converter: Tunnelgeist::Protocol::AddressConverter)]
      getter address : Address

      # Built by the client; the daemon reads it with `Request.parse`.
      def initialize(*, @name : InterfaceName, @key : Key, @address : Address)
        @version = VERSION
        @operation = self.class.operation
      end

      def_equals name, key, address

      protected def inspect_subject(io : IO) : Nil
        io << "address="
        @address.inspect(io)
      end
    end
  end
end
