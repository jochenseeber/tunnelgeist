{% skip_file unless flag?(:darwin) %}

require "../address"
require "../client"
require "../interface_name"
require "../prefix"
require "../protocol"

class Tunnelgeist::Client
  # A device `create` made: its name and its utun descriptor. The descriptor
  # goes with every change, so the daemon knows the request comes from the
  # device's holder and holds the device while it changes it; holding the
  # descriptor is what lets a process change the device.
  class Device
    # The name the kernel gave the device.
    getter name : InterfaceName
    # The utun descriptor, owned by the caller, who closes it. It has
    # close-on-exec set and is blocking: `FdPassing.receive` leaves the
    # flags of the open file description as the daemon made it, and the
    # daemon makes it blocking.
    getter fd : Int32
    # The MTU the device was created with.
    getter mtu : Int32

    protected def initialize(@client : Client, *, @name : InterfaceName, @mtu : Int32, @fd : Int32)
    end

    # Adds *address* to the device. Raises `Client::Error` when the daemon
    # refuses.
    def add_address(address : Address) : Nil
      change(Protocol::AddAddress.new(name: @name, address: address))
    end

    # Removes *address* from the device. Raises `Client::Error` when the daemon
    # refuses.
    def remove_address(address : Address) : Nil
      change(Protocol::RemoveAddress.new(name: @name, address: address))
    end

    # Routes *route* through the device. Raises `Client::Error` when the daemon
    # refuses.
    def add_route(route : Prefix) : Nil
      change(Protocol::AddRoute.new(name: @name, route: route))
    end

    # Removes the route *route* of the device. Raises `Client::Error` when the
    # daemon refuses.
    def remove_route(route : Prefix) : Nil
      change(Protocol::RemoveRoute.new(name: @name, route: route))
    end

    # Sends *request* with the device's descriptor.
    private def change(request : Protocol::DeviceRequest) : Nil
      @client.exchange(request, fd: @fd)
    end
  end
end
