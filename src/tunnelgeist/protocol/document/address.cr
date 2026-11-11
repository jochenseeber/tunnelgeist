{% skip_file unless flag?(:darwin) %}

require "json"
require "../../address"
require "../integer_converter"
require "../strict_fields"
require "../text_converter"

module Tunnelgeist
  module Protocol
    module Document
      # :nodoc:
      # An address object as the wire has it (UP2): the address and the peer
      # as text, so that `AddressConverter` can check them with errors that
      # name their fields.
      struct Address
        include JSON::Serializable
        include StrictFields

        # The address literal.
        @[JSON::Field(converter: Tunnelgeist::Protocol::TextConverter(String).new("address"))]
        getter address : String
        # The prefix length.
        @[JSON::Field(converter: Tunnelgeist::Protocol::IntegerConverter.new("prefix"))]
        getter prefix : Int32
        # The peer literal; nil for an address without a peer.
        @[JSON::Field(converter: Tunnelgeist::Protocol::TextConverter(String).new("peer", nullable: true))]
        getter peer : String?

        # The wire shape of *address*.
        def initialize(address : Tunnelgeist::Address)
          @address = address.address.address
          @prefix = address.prefix
          @peer = address.peer.try(&.address)
        end

        # The peer literal; raises `NilAssertionError` for an address without
        # a peer.
        def peer! : String
          @peer || raise NilAssertionError.new("the address #{@address} has no peer")
        end
      end
    end
  end
end
