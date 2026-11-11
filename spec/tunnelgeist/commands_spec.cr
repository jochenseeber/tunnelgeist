require "../spec_helper"
require "../../src/tunnelgeist/commands"

# The ifconfig and route argument vectors of `Tunnelgeist::Commands`.
describe Tunnelgeist::Commands do
  {% if flag?(:darwin) %}
    def ifname(text : String) : Tunnelgeist::InterfaceName
      Tunnelgeist::InterfaceName.new(text)
    end

    def v4 : Tunnelgeist::Address
      Tunnelgeist::Address.new(Socket::IPAddress.new("10.77.0.1", 0), prefix: 24, peer: Socket::IPAddress.new("10.77.0.2", 0))
    end

    def v6 : Tunnelgeist::Address
      Tunnelgeist::Address.new(Socket::IPAddress.new("fd77::1", 0), prefix: 64)
    end

    test "up brings the interface up" do
      assert(Tunnelgeist::Commands.up(ifname("utun5")) == ["/sbin/ifconfig", "utun5", "up"])
    end

    test "add_address makes an IPv4 point-to-point alias with the netmask" do
      assert(Tunnelgeist::Commands.add_address(v4, name: ifname("utun5")) ==
             ["/sbin/ifconfig", "utun5", "inet", "10.77.0.1", "10.77.0.2", "netmask", "255.255.255.0", "alias"])
    end

    test "remove_address removes an IPv4 alias" do
      assert(Tunnelgeist::Commands.remove_address(v4, name: ifname("utun5")) ==
             ["/sbin/ifconfig", "utun5", "inet", "10.77.0.1", "-alias"])
    end

    test "add_address makes an IPv6 alias with the prefix length" do
      assert(Tunnelgeist::Commands.add_address(v6, name: ifname("utun5")) ==
             ["/sbin/ifconfig", "utun5", "inet6", "fd77::1", "prefixlen", "64", "alias"])
    end

    test "remove_address removes an IPv6 alias" do
      assert(Tunnelgeist::Commands.remove_address(v6, name: ifname("utun5")) ==
             ["/sbin/ifconfig", "utun5", "inet6", "fd77::1", "-alias"])
    end

    test "add_route and remove_route name the prefix and the interface" do
      assert(Tunnelgeist::Commands.add_route(Tunnelgeist::Prefix.parse("10.99.0.0/16"), name: ifname("utun5")) ==
             ["/sbin/route", "-n", "add", "-inet", "10.99.0.0/16", "-interface", "utun5"])
      assert(Tunnelgeist::Commands.remove_route(Tunnelgeist::Prefix.parse("fd99::/48"), name: ifname("utun5")) ==
             ["/sbin/route", "-n", "delete", "-inet6", "fd99::/48", "-interface", "utun5"])
    end

    test "get_route asks for the route of the prefix by family" do
      assert(Tunnelgeist::Commands.get_route(Tunnelgeist::Prefix.parse("10.99.0.0/16")) ==
             ["/sbin/route", "-n", "get", "-inet", "10.99.0.0/16"])
      assert(Tunnelgeist::Commands.get_route(Tunnelgeist::Prefix.parse("fd99::/48")) ==
             ["/sbin/route", "-n", "get", "-inet6", "fd99::/48"])
    end

    test "routes_to? reads the interface line of route get exactly" do
      output = "   route to: 10.99.0.0\ndestination: 10.99.0.0\n  interface: utun10\n      flags: <UP,DONE,STATIC>\n"
      assert(Tunnelgeist::Commands.routes_to?(output, name: ifname("utun10")))
      assert(!Tunnelgeist::Commands.routes_to?(output, name: ifname("utun1")))
      assert(!Tunnelgeist::Commands.routes_to?(output.sub("utun10", "utun1"), name: ifname("utun10")))
      assert(!Tunnelgeist::Commands.routes_to?("", name: ifname("utun10")))
    end

    test "netmask converts a prefix length to a dotted mask" do
      assert(Tunnelgeist::Commands.netmask(0) == "0.0.0.0")
      assert(Tunnelgeist::Commands.netmask(24) == "255.255.255.0")
      assert(Tunnelgeist::Commands.netmask(32) == "255.255.255.255")
    end

    test "netmask rejects a length outside 0..32" do
      assert(raised(ArgumentError) { Tunnelgeist::Commands.netmask(33) })
      assert(raised(ArgumentError) { Tunnelgeist::Commands.netmask(-1) })
    end
  {% end %}
end
