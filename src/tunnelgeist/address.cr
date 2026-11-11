{% skip_file unless flag?(:darwin) %}

require "socket"
require "./family"

module Tunnelgeist
  # An address of the kernel side of a utun interface (UA4): the local
  # address, the prefix length and, for IPv4, the point-to-point peer.
  # Every constructor checks the combination.
  struct Address
    # The address assigned to the interface.
    getter address : Socket::IPAddress
    # The mask length in bits, 0..32 for IPv4 and 0..128 for IPv6.
    getter prefix : Int32
    # The other end of the point-to-point link; always set for IPv4, nil for
    # IPv6.
    getter peer : Socket::IPAddress?

    def_equals_and_hash address, prefix, peer

    # Raises `ArgumentError` when *prefix* is outside 0..32 (IPv4) or
    # 0..128 (IPv6), when an IPv4 address has no *peer*, when *peer* is of
    # another family than *address*, or when an IPv6 address has a *peer*.
    def initialize(@address : Socket::IPAddress, *, @prefix : Int32, @peer : Socket::IPAddress? = nil)
      limit = Family.of(@address.family).prefix_limit
      raise ArgumentError.new("Prefix length #{@prefix} outside 0..#{limit}") unless 0 <= @prefix <= limit

      peer = @peer
      if @address.family.inet6?
        raise ArgumentError.new("An IPv6 address takes no peer, got #{peer.address}") if peer
      else
        raise ArgumentError.new("An IPv4 address needs a peer") unless peer
        raise ArgumentError.new("The peer #{peer.address} is not an IPv4 address") unless peer.family.inet?
      end
    end

    # The peer; raises `NilAssertionError` for an IPv6 address, which has none.
    def peer! : Socket::IPAddress
      @peer || raise NilAssertionError.new("an IPv6 address has no peer")
    end

    # Whether *other* has the same local address, in whatever prefix length or
    # peer. The kernel keeps one alias per family and local address on a
    # device, so this is the identity of an alias there. `Socket::IPAddress`
    # holds the address normalized, so `FD77::0:1` equals `fd77::1`.
    def same_local?(other : Address) : Bool
      @address == other.address
    end

    # Whether the address is IPv4 or IPv6, which decides the `ifconfig` keyword
    # and the prefix limit.
    def family : Socket::Family
      @address.family
    end
  end
end
