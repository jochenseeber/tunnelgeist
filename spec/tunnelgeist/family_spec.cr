require "../spec_helper"
require "../../src/tunnelgeist/family"

describe Tunnelgeist::Family do
  {% if flag?(:darwin) %}
    test "of describes IPv4" do
      family = Tunnelgeist::Family.of(Socket::Family::INET)
      assert(family.prefix_limit == 32)
      assert(family.ifconfig_keyword == "inet")
      assert(family.route_flag == "-inet")
    end

    test "of describes IPv6" do
      family = Tunnelgeist::Family.of(Socket::Family::INET6)
      assert(family.prefix_limit == 128)
      assert(family.ifconfig_keyword == "inet6")
      assert(family.route_flag == "-inet6")
    end

    test "of rejects any other family" do
      assert(raised(ArgumentError) { Tunnelgeist::Family.of(Socket::Family::UNIX) })
    end
  {% end %}
end
