{% skip_file unless flag?(:darwin) %}

require "socket"

module Tunnelgeist
  # What the code knows about an IP address family: the longest prefix and
  # the words `ifconfig` and `route` use for it.
  record Family, prefix_limit : Int32, ifconfig_keyword : String, route_flag : String do
    # The `Family` of *socket_family*. Raises `ArgumentError` for any family
    # other than IPv4 and IPv6.
    def self.of(socket_family : Socket::Family) : Family
      case socket_family
      when .inet?  then new(prefix_limit: 32, ifconfig_keyword: "inet", route_flag: "-inet")
      when .inet6? then new(prefix_limit: 128, ifconfig_keyword: "inet6", route_flag: "-inet6")
      else              raise ArgumentError.new("Unsupported address family #{socket_family}")
      end
    end
  end
end
