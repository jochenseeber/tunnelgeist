{% skip_file unless flag?(:darwin) %}

require "./address"
require "./family"
require "./interface_name"
require "./prefix"
require "./commands/route_verb"

module Tunnelgeist
  # The argument vectors that configure the kernel side of a utun
  # interface (UA3), element 0 being the absolute path of the program.
  # The root daemon runs them and `tunnelgeist tun` prints them, so the two
  # cannot drift apart.
  module Commands
    # The program that configures interfaces.
    IFCONFIG = "/sbin/ifconfig"
    # The program that edits and shows routes.
    ROUTE = "/sbin/route"

    # Brings the interface *name* up.
    def self.up(name : InterfaceName) : Array(String)
      [IFCONFIG, name.to_s, "up"]
    end

    # Adds *address* as an alias: point to point with the netmask for
    # IPv4, with the prefix length for IPv6.
    def self.add_address(address : Address, *, name : InterfaceName) : Array(String)
      local = address.address.address
      keyword = Family.of(address.family).ifconfig_keyword
      if address.family.inet6?
        [IFCONFIG, name.to_s, keyword, local, "prefixlen", address.prefix.to_s, "alias"]
      else
        [IFCONFIG, name.to_s, keyword, local, address.peer!.address, "netmask", netmask(address.prefix), "alias"]
      end
    end

    # Removes the alias *address*.
    def self.remove_address(address : Address, *, name : InterfaceName) : Array(String)
      [IFCONFIG, name.to_s, Family.of(address.family).ifconfig_keyword, address.address.address, "-alias"]
    end

    # Routes *prefix* to the interface *name*.
    def self.add_route(prefix : Prefix, *, name : InterfaceName) : Array(String)
      route(RouteVerb::Add, name: name, prefix: prefix)
    end

    # Removes the route of *prefix* to the interface *name*.
    def self.remove_route(prefix : Prefix, *, name : InterfaceName) : Array(String)
      route(RouteVerb::Delete, name: name, prefix: prefix)
    end

    # Asks the kernel for its route of *prefix*; the standard output names
    # the interface it points at, which `routes_to?` reads.
    def self.get_route(prefix : Prefix) : Array(String)
      [ROUTE, "-n", "get", Family.of(prefix.family).route_flag, prefix.to_s]
    end

    # Whether *output* of `get_route` names the interface *name*: a line
    # that is `interface: NAME` and nothing else, so utun1 does not match
    # utun10.
    def self.routes_to?(output : String, *, name : InterfaceName) : Bool
      output.each_line.any? { |line| line.strip == "interface: #{name}" }
    end

    # The dotted IPv4 netmask of a prefix of *bits* bits, such as
    # `255.255.255.0` for 24.
    # Raises `ArgumentError` when *bits* is outside 0..32.
    def self.netmask(bits : Int32) : String
      raise ArgumentError.new("Prefix length #{bits} outside 0..32") unless 0 <= bits <= 32

      mask = (0xffff_ffff_u64 << (32 - bits)).to_u32!
      [(mask >> 24).to_u8!, (mask >> 16).to_u8!, (mask >> 8).to_u8!, mask.to_u8!].join('.')
    end

    private def self.route(verb : RouteVerb, *, name : InterfaceName, prefix : Prefix) : Array(String)
      [ROUTE, "-n", verb.word, Family.of(prefix.family).route_flag, prefix.to_s, "-interface", name.to_s]
    end
  end
end
