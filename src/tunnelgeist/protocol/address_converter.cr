{% skip_file unless flag?(:darwin) %}

require "json"
require "socket"
require "../address"
require "../family"
require "../prefix"
require "./common"
require "./document/address"
require "./error"

module Tunnelgeist
  module Protocol
    # :nodoc:
    # The `JSON::Field` converter of an address object (UP2), a field of its
    # own or an element of `addresses`.
    module AddressConverter
      # The address *pull* is at. Raises `Error` naming the field of the
      # object that is missing, mistyped, unknown or invalid.
      def self.from_json(pull : JSON::PullParser) : Address
        document = Protocol.read(Document::Address, pull: pull, what: "address")
        address = begin
          Prefix.parse_address(document.address)
        rescue Prefix::ParseError
          raise Error.new("invalid address #{document.address.inspect}", field: "address")
        end
        prefix = document.prefix
        peer = document.peer.try { |text| parse_peer(text) }

        # The conditions of `Address#initialize`, checked here so that each
        # error names its own field.
        limit = Family.of(address.family).prefix_limit
        raise Error.new("Prefix length #{prefix} outside 0..#{limit}", field: "prefix") unless 0 <= prefix <= limit
        if address.family.inet6?
          raise Error.new("An IPv6 address takes no peer, got #{peer.address}", field: "peer") if peer
        else
          raise Error.new("An IPv4 address needs a peer", field: "peer") unless peer
          raise Error.new("The peer #{peer.address} is not an IPv4 address", field: "peer") unless peer.family.inet?
        end

        Address.new(address, prefix: prefix, peer: peer)
      end

      # Writes *value* as the address object; the converter protocol of
      # `JSON::Field` passes both positionally.
      def self.to_json(value : Address, json : JSON::Builder) : Nil
        Document::Address.new(value).to_json(json)
      end

      private def self.parse_peer(text : String) : Socket::IPAddress
        Prefix.parse_address(text)
      rescue Prefix::ParseError
        raise Error.new("invalid peer #{text.inspect}", field: "peer")
      end
    end
  end
end
