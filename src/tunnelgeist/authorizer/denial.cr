{% skip_file unless flag?(:darwin) %}

require "../address"
require "../prefix"
require "./denial/kind"

module Tunnelgeist
  class Authorizer
    # A request item that no client configuration applying to the peer
    # allows (CA3): its kind and its text as the error reply names it. The
    # text is the canonical form (`Socket::IPAddress#address`,
    # `Prefix#to_s`), as the log lines write addresses, so an IPv6 item the
    # request wrote uncompressed comes back compressed.
    record Denial, kind : Kind, text : String do
      # The denial of *address*, named by its local address and prefix
      # length, such as `10.1.2.3/24`.
      def self.address(address : Address) : Denial
        new(kind: :address, text: "#{address.address.address}/#{address.prefix}")
      end

      # The denial of the route to *destination*, named by the prefix, such
      # as `10.77.0.0/16`.
      def self.route(destination : Prefix) : Denial
        new(kind: :route, text: destination.to_s)
      end

      # The text of the error reply: `address 10.1.2.3/24 not allowed` or
      # `route 10.77.0.0/16 not allowed`.
      def message : String
        noun = case kind
               in .address? then "address"
               in .route?   then "route"
               end
        "#{noun} #{text} not allowed"
      end
    end
  end
end
