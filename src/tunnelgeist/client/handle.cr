{% skip_file unless flag?(:darwin) %}

require "../address"
require "../interface_name"
require "../key"
require "../prefix"
require "../protocol"

class Tunnelgeist::Client
  # A device the daemon made, known by its name and key.
  class Handle
    # The name the kernel gave the device; with `key` it identifies the device
    # to the daemon.
    getter name : InterfaceName
    # The bearer key that authorizes changes to the device.
    getter key : Key

    protected def initialize(@client : Client, *, @name : InterfaceName, @key : Key)
    end

    # The key never reaches a log line or `pp` output, so the default
    # `inspect` and `to_s` are replaced.
    def inspect(io : IO) : Nil
      io << "#<" << self.class.name.split("::").last << " name=" << @name.to_s.inspect << " key=[REDACTED]>"
    end

    # Same as `inspect`, so the key stays out of string interpolation.
    def to_s(io : IO) : Nil
      inspect(io)
    end

    # Adds *address* to the device. Raises `Client::Error` when the daemon
    # refuses.
    def add_address(address : Address) : Nil
      @client.exchange(Protocol::AddAddress.new(name: @name, key: @key, address: address))
    end

    # Removes *address* from the device. Raises `Client::Error` when the daemon
    # refuses.
    def remove_address(address : Address) : Nil
      @client.exchange(Protocol::RemoveAddress.new(name: @name, key: @key, address: address))
    end

    # Routes *route* through the device. Raises `Client::Error` when the daemon
    # refuses.
    def add_route(route : Prefix) : Nil
      @client.exchange(Protocol::AddRoute.new(name: @name, key: @key, route: route))
    end

    # Removes the route *route* of the device. Raises `Client::Error` when the
    # daemon refuses.
    def remove_route(route : Prefix) : Nil
      @client.exchange(Protocol::RemoveRoute.new(name: @name, key: @key, route: route))
    end
  end
end

# `Client#exchange` is defined there. Required after `Handle`, because
# `client.cr` requires `client/device.cr`, whose `Device < Handle` needs
# `Handle` to exist when this file is the first one loaded.
require "../client"
