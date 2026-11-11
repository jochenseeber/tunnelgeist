{% skip_file unless flag?(:darwin) %}

require "json"
require "../address"
require "../interface_name"
require "../prefix"
require "./address_converter"
require "./common"
require "./error"
require "./integer_converter"
require "./list_converter"
require "./operation"
require "./request"
require "./text_converter"

module Tunnelgeist
  module Protocol
    # Asks the daemon to create a utun device, configure it with the addresses
    # and routes and reply with its name and its descriptor.
    struct Create < Request
      # The requested device name; nil leaves the choice to the daemon, and
      # the wire carries null.
      @[JSON::Field(emit_null: true, converter: Tunnelgeist::Protocol::TextConverter(Tunnelgeist::InterfaceName).new("name", nullable: true))]
      getter name : InterfaceName?
      # The MTU of the new device.
      @[JSON::Field(converter: Tunnelgeist::Protocol::IntegerConverter.new("mtu"))]
      getter mtu : Int32
      # The addresses to configure on the new device.
      @[JSON::Field(converter: Tunnelgeist::Protocol::ListConverter.new("addresses", limit: Tunnelgeist::Protocol::MAX_ADDRESSES, element: Tunnelgeist::Protocol::AddressConverter))]
      getter addresses : Array(Address)
      # The routes to add through the new device.
      @[JSON::Field(converter: Tunnelgeist::Protocol::ListConverter.new("routes", limit: Tunnelgeist::Protocol::MAX_ROUTES, element: Tunnelgeist::Protocol::TextConverter(Tunnelgeist::Prefix).new("routes", subject: "route")))]
      getter routes : Array(Prefix)

      # The operation of every request of this type.
      def self.operation : Operation
        Operation::Create
      end

      # The settings are not checked here: the reader enforces the limits of
      # the protocol on what arrives, so a locally built request may break
      # them.
      def initialize(*, @name : InterfaceName?, @mtu : Int32, @addresses : Array(Address), @routes : Array(Prefix))
        @version = VERSION
        @operation = self.class.operation
      end

      # The name; raises `NilAssertionError` when the request leaves the
      # choice to the daemon.
      def name! : InterfaceName
        @name || raise NilAssertionError.new("the request names no device")
      end

      def_equals name, mtu, addresses, routes

      # The converters check the number of addresses and routes; the MTU
      # range and the uniqueness of the local addresses are checked here.
      protected def after_initialize : Nil
        super
        @addresses.each_with_index do |address, index|
          if @addresses.first(index).any?(&.same_local?(address))
            raise Error.new("address #{address.address.address} listed twice", field: "addresses")
          end
        end
        raise Error.new("mtu #{@mtu} outside #{MTU_RANGE}", field: "mtu") unless MTU_RANGE.includes?(@mtu)
      end
    end
  end
end
