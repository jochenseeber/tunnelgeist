{% skip_file unless flag?(:darwin) %}

require "socket"
require "./decimal"
require "./family"
require "./prefix/parse_error"

module Tunnelgeist
  # An IP address with a prefix length, such as `10.64.0.0/10`. Unlike a
  # network, the address may carry host bits; `#host_bits?` tells.
  struct Prefix
    # The address; it keeps whatever port it was built with.
    getter address : Socket::IPAddress
    # The number of leading bits that count.
    getter bits : Int32

    def_equals_and_hash address, bits

    # Raises `ArgumentError` when *bits* is outside 0..32 (IPv4) or 0..128
    # (IPv6).
    def initialize(@address : Socket::IPAddress, *, @bits : Int32)
      limit = Family.of(@address.family).prefix_limit
      raise ArgumentError.new("Prefix length #{@bits} outside 0..#{limit}") unless 0 <= @bits <= limit
    end

    # Parses `"10.64.0.0/10"` or `"fd7a:115c:a1e0::/48"`: the length is
    # required and has no leading zero. Raises `ParseError` for anything else,
    # including a bare address and a zone.
    def self.parse(text : String) : Prefix
      address_text, separator, bits_text = text.partition('/')
      raise ParseError.new(text, reason: "missing prefix length") if separator.empty?

      address = begin
        parse_address(address_text)
      rescue error : ParseError
        raise ParseError.new(text, reason: error.reason)
      end

      raise ParseError.new(text, reason: "invalid prefix length") unless Decimal.canonical?(bits_text)

      bits = bits_text.to_i?
      raise ParseError.new(text, reason: "prefix length out of range") unless bits && bits <= Family.of(address.family).prefix_limit

      new(address, bits: bits)
    end

    # Parses a bare address. Raises `ParseError` when *text* has a zone (`%`),
    # which `Socket::IPAddress` would silently drop, or is not an address.
    def self.parse_address(text : String) : Socket::IPAddress
      raise ParseError.new(text, reason: "zones are not supported") if text.includes?('%')

      Socket::IPAddress.new(text, 0)
    rescue Socket::Error
      raise ParseError.new(text, reason: "invalid address")
    end

    # The address family of the prefix.
    def family : Socket::Family
      @address.family
    end

    # Whether any bit of the address after the first `bits` is set.
    def host_bits? : Bool
      each_field do |value, mask|
        return true unless (value & ~mask) == 0
      end

      false
    end

    # The prefix with its host bits cleared: `10.1.2.3/8` becomes `10.0.0.0/8`.
    # The result keeps the port of the address, which is not part of the prefix.
    def network : Prefix
      fields = network_fields
      text = family.inet6? ? fields.map(&.to_s(16)).join(':') : fields.join('.')
      Prefix.new(Socket::IPAddress.new(text, @address.port), bits: @bits)
    end

    # Whether *other* lies inside this prefix: the same family, at least as long
    # as this one, and equal in the first `bits` bits. A prefix includes itself.
    # Host bits of either prefix are ignored, so `10.1.2.3/8` includes
    # `10.9.9.9/16`.
    def includes?(other : Prefix) : Bool
      other.bits >= @bits && includes?(other.address)
    end

    # Whether *address* lies inside this prefix: the same family and equal in
    # the first `bits` bits. The port of the address does not matter.
    def includes?(address : Socket::IPAddress) : Bool
      return false unless address.family == family

      network_fields == Prefix.new(address, bits: @bits).network_fields
    end

    # The address fields (16-bit words for IPv6, bytes for IPv4, widened) with
    # the host bits cleared.
    protected def network_fields : Array(UInt16)
      fields = [] of UInt16
      each_field { |value, mask| fields << (value & mask) }
      fields
    end

    # Yields each address field with the mask of the bits of it that count.
    # Yields nothing when the address text does not parse into fields.
    private def each_field(& : UInt16, UInt16 ->) : Nil
      width = family.inet6? ? 16 : 8
      fields = if family.inet6?
                 Socket::IPAddress.parse_v6_fields?(@address.address)
               else
                 Socket::IPAddress.parse_v4_fields?(@address.address).try(&.map(&.to_u16))
               end
      return unless fields

      full = (1_u16 << width) &- 1
      fields.each_with_index do |value, index|
        keep = Math.min(Math.max(@bits - (index * width), 0), width)
        yield value.to_u16, (full << (width - keep)) & full
      end
    end

    # Writes `address/bits`, for example `10.64.0.0/10`.
    def to_s(io : IO) : Nil
      io << @address.address << '/' << @bits
    end
  end
end
