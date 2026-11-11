require "../spec_helper"
require "../../src/tunnelgeist/prefix"

describe Tunnelgeist::Prefix do
  {% if flag?(:darwin) %}
    test "parse reads an IPv4 and an IPv6 prefix" do
      v4 = Tunnelgeist::Prefix.parse("10.64.0.0/10")
      assert(v4.address.address == "10.64.0.0")
      assert(v4.bits == 10)
      assert(v4.family.inet?)

      v6 = Tunnelgeist::Prefix.parse("fd7a:115c:a1e0::/48")
      assert(v6.address.address == "fd7a:115c:a1e0::")
      assert(v6.bits == 48)
      assert(v6.family.inet6?)
    end

    test "parse rejects what is not a prefix" do
      ["10.0.0.0", "10.0.0.0/08", "10.0.0.0/33", "fd00::/129", "fe80::1%en0/64", "01.2.3.4/8",
       "10.0.0.0/", "10.0.0.0/-1", "10.0.0.0/8 ", "/8", "x/8"].each do |text|
        error = raised(Tunnelgeist::Prefix::ParseError) { Tunnelgeist::Prefix.parse(text) }
        assert(error.message.to_s.starts_with?("invalid prefix #{text.inspect}: "))
      end
    end

    test "parse refuses a length that is not plain ASCII decimal without a leading zero" do
      ["10.0.0.0/٨", "10.0.0.0/８", "10.0.0.0/8\n", "10.0.0.0/+8", "10.0.0.0/00", "10.0.0.0/1_0", "10.0.0.0/ 8",
       "10.0.0.0/8/8"].each do |text|
        error = raised(Tunnelgeist::Prefix::ParseError) { Tunnelgeist::Prefix.parse(text) }
        assert(error.reason == "invalid prefix length")
      end
      assert(Tunnelgeist::Prefix.parse("10.0.0.0/0").bits == 0)
      assert(Tunnelgeist::Prefix.parse("fd00::/128").bits == 128)
    end

    test "parse keeps the reason of the address error even when the address text holds a colon and a space" do
      error = raised(Tunnelgeist::Prefix::ParseError) { Tunnelgeist::Prefix.parse("x: y/8") }
      assert(error.reason == "invalid address")
      assert(error.message == %(invalid prefix "x: y/8": invalid address))
      zone = raised(Tunnelgeist::Prefix::ParseError) { Tunnelgeist::Prefix.parse("fe80::1%en0/64") }
      assert(zone.reason == "zones are not supported")
    end

    test "parse_address rejects a zone and a malformed address" do
      assert(Tunnelgeist::Prefix.parse_address("fd00::1").family.inet6?)
      assert(raised(Tunnelgeist::Prefix::ParseError) { Tunnelgeist::Prefix.parse_address("fe80::1%en0") })
      assert(raised(Tunnelgeist::Prefix::ParseError) { Tunnelgeist::Prefix.parse_address("10.0.0") })
    end

    test "new rejects a length outside the family's range" do
      v4 = Socket::IPAddress.new("10.0.0.0", 0)
      v6 = Socket::IPAddress.new("fd00::", 0)
      assert(raised(ArgumentError) { Tunnelgeist::Prefix.new(v4, bits: 33) })
      assert(raised(ArgumentError) { Tunnelgeist::Prefix.new(v4, bits: -1) })
      assert(raised(ArgumentError) { Tunnelgeist::Prefix.new(v6, bits: 129) })
      assert(Tunnelgeist::Prefix.new(v6, bits: 128).bits == 128)
    end

    test "host_bits? is true when a bit after the length is set" do
      assert(Tunnelgeist::Prefix.parse("10.99.0.1/16").host_bits?)
      assert(Tunnelgeist::Prefix.parse("fd99::1/48").host_bits?)
      assert(!Tunnelgeist::Prefix.parse("10.99.0.0/16").host_bits?)
      assert(!Tunnelgeist::Prefix.parse("0.0.0.0/0").host_bits?)
      assert(!Tunnelgeist::Prefix.parse("10.1.2.3/32").host_bits?)
      assert(!Tunnelgeist::Prefix.parse("fd99::/48").host_bits?)
      assert(Tunnelgeist::Prefix.parse("10.0.0.128/25").host_bits? == false)
      assert(Tunnelgeist::Prefix.parse("10.0.0.129/25").host_bits?)
    end

    test "includes? tells whether another prefix lies inside" do
      ten = Tunnelgeist::Prefix.parse("10.0.0.0/8")
      assert(ten.includes?(Tunnelgeist::Prefix.parse("10.77.0.0/16")))
      assert(ten.includes?(Tunnelgeist::Prefix.parse("10.0.0.0/8")))
      assert(ten.includes?(Tunnelgeist::Prefix.parse("10.1.2.3/32")))
      assert(!ten.includes?(Tunnelgeist::Prefix.parse("10.1.2.3/7")))
      assert(!ten.includes?(Tunnelgeist::Prefix.parse("11.0.0.0/8")))
      assert(!ten.includes?(Tunnelgeist::Prefix.parse("fd00::/8")))
      assert(Tunnelgeist::Prefix.parse("fc00::/7").includes?(Tunnelgeist::Prefix.parse("fd7a:115c::/48")))
      assert(!Tunnelgeist::Prefix.parse("fd7a:115c::/48").includes?(Tunnelgeist::Prefix.parse("fc00::/7")))
      assert(!Tunnelgeist::Prefix.parse("fc00::/7").includes?(Tunnelgeist::Prefix.parse("fe00::/9")))
    end

    test "includes? ignores host bits of the receiver and of the argument" do
      assert(Tunnelgeist::Prefix.parse("10.1.2.3/8").includes?(Tunnelgeist::Prefix.parse("10.9.9.9/16")))
      assert(!Tunnelgeist::Prefix.parse("10.1.0.0/16").includes?(Tunnelgeist::Prefix.parse("10.1.2.3/8")))
    end

    test "the prefix of length zero includes every prefix of its family only" do
      any = Tunnelgeist::Prefix.parse("0.0.0.0/0")
      assert(any.includes?(Tunnelgeist::Prefix.parse("10.0.0.0/8")))
      assert(any.includes?(Tunnelgeist::Prefix.parse("255.255.255.255/32")))
      assert(!any.includes?(Tunnelgeist::Prefix.parse("::/0")))
      assert(!any.includes?(Tunnelgeist::Prefix.parse("fd00::/8")))
    end

    test "includes? tells whether an address lies inside" do
      ten = Tunnelgeist::Prefix.parse("10.0.0.0/8")
      assert(ten.includes?(Tunnelgeist::Prefix.parse_address("10.9.8.7")))
      assert(!ten.includes?(Tunnelgeist::Prefix.parse_address("172.16.0.1")))
      assert(!ten.includes?(Tunnelgeist::Prefix.parse_address("fd00::1")))
      assert(Tunnelgeist::Prefix.parse("fc00::/7").includes?(Tunnelgeist::Prefix.parse_address("fd00::1")))
    end

    test "network clears the host bits" do
      assert(Tunnelgeist::Prefix.parse("10.1.2.3/8").network == Tunnelgeist::Prefix.parse("10.0.0.0/8"))
      assert(Tunnelgeist::Prefix.parse("fd99::1/48").network == Tunnelgeist::Prefix.parse("fd99::/48"))
      assert(Tunnelgeist::Prefix.parse("10.1.2.3/32").network == Tunnelgeist::Prefix.parse("10.1.2.3/32"))
      assert(Tunnelgeist::Prefix.parse("10.1.2.3/0").network == Tunnelgeist::Prefix.parse("0.0.0.0/0"))
    end

    test "to_s round-trips" do
      ["10.64.0.0/10", "fd7a:115c:a1e0::/48", "0.0.0.0/0"].each do |text|
        assert(Tunnelgeist::Prefix.parse(text).to_s == text)
      end
    end

    test "prefixes are equal by value" do
      assert(Tunnelgeist::Prefix.parse("10.0.0.0/8") == Tunnelgeist::Prefix.parse("10.0.0.0/8"))
      assert(Tunnelgeist::Prefix.parse("10.0.0.0/8") != Tunnelgeist::Prefix.parse("10.0.0.0/9"))
      assert(Tunnelgeist::Prefix.parse("10.0.0.0/8").hash == Tunnelgeist::Prefix.parse("10.0.0.0/8").hash)
    end
  {% end %}
end
