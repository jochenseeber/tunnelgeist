require "../spec_helper"
require "../../src/tunnelgeist/address"

# The checks of `Tunnelgeist::Address.new` and its accessors.
describe Tunnelgeist::Address do
  {% if flag?(:darwin) %}
    def v4 : Tunnelgeist::Address
      Tunnelgeist::Address.new(Socket::IPAddress.new("10.77.0.1", 0), prefix: 24, peer: Socket::IPAddress.new("10.77.0.2", 0))
    end

    def v6 : Tunnelgeist::Address
      Tunnelgeist::Address.new(Socket::IPAddress.new("fd77::1", 0), prefix: 64)
    end

    test "Address#peer! returns the peer and raises for an IPv6 address" do
      peer = Socket::IPAddress.new("10.77.0.2", 0)
      v4 = Tunnelgeist::Address.new(Socket::IPAddress.new("10.77.0.1", 0), prefix: 24, peer: peer)
      v6 = Tunnelgeist::Address.new(Socket::IPAddress.new("fd77::1", 0), prefix: 64)

      assert(v4.peer! == peer)
      assert(raised(NilAssertionError) { v6.peer! }.message.to_s.includes?("no peer"))
    end

    test "Address.new rejects what the kernel cannot take" do
      address = Tunnelgeist::Address
      ip4 = Socket::IPAddress.new("10.77.0.1", 0)
      ip6 = Socket::IPAddress.new("fd77::1", 0)

      assert(raised(ArgumentError) { address.new(ip4, prefix: 33, peer: ip4) })
      assert(raised(ArgumentError) { address.new(ip4, prefix: -1, peer: ip4) })
      assert(raised(ArgumentError) { address.new(ip4, prefix: 99, peer: ip4) })
      assert(raised(ArgumentError) { address.new(ip6, prefix: 129) })
      assert(raised(ArgumentError) { address.new(ip4, prefix: 24) })
      assert(raised(ArgumentError) { address.new(ip4, prefix: 24, peer: ip6) })
      assert(raised(ArgumentError) { address.new(ip6, prefix: 64, peer: ip4) })
      assert(raised(ArgumentError) { address.new(ip6, prefix: 64, peer: ip6) })
      assert(address.new(ip6, prefix: 64) == v6)
    end

    test "Address#family is the family of the address" do
      assert(v4.family.inet?)
      assert(v6.family.inet6?)
    end
  {% end %}
end
