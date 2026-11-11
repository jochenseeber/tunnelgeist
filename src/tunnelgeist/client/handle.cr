{% skip_file unless flag?(:darwin) %}

require "../address"
require "../interface_name"
require "../key"
require "../prefix"
require "../protocol"
require "./error"

class Tunnelgeist::Client
  # A device the daemon made, known by its name and key, without its
  # descriptor. The daemon changes a device only for a request that carries
  # the device's descriptor, so a handle cannot change its device: its
  # change methods raise `Client::Error` with reason `NoDescriptor` and ask
  # the daemon nothing. `Client::Device` holds the descriptor and changes
  # the device.
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
    # refuses, and always for a handle that is not a `Client::Device`.
    def add_address(address : Address) : Nil
      change(Protocol::AddAddress.new(name: @name, key: @key, address: address))
    end

    # Removes *address* from the device. Raises `Client::Error` when the daemon
    # refuses, and always for a handle that is not a `Client::Device`.
    def remove_address(address : Address) : Nil
      change(Protocol::RemoveAddress.new(name: @name, key: @key, address: address))
    end

    # Routes *route* through the device. Raises `Client::Error` when the daemon
    # refuses, and always for a handle that is not a `Client::Device`.
    def add_route(route : Prefix) : Nil
      change(Protocol::AddRoute.new(name: @name, key: @key, route: route))
    end

    # Removes the route *route* of the device. Raises `Client::Error` when the
    # daemon refuses, and always for a handle that is not a `Client::Device`.
    def remove_route(route : Prefix) : Nil
      change(Protocol::RemoveRoute.new(name: @name, key: @key, route: route))
    end

    # Sends *request* to the daemon. A handle has no descriptor to send with
    # it, so it raises `Client::Error` with reason `NoDescriptor` instead;
    # `Client::Device` sends its own.
    protected def change(request : Protocol::DeviceRequest) : Nil
      raise Error.new("a handle cannot change #{@name}: a change needs the device's descriptor", reason: Error::Reason::NoDescriptor)
    end
  end
end
