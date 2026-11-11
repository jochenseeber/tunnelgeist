{% skip_file unless flag?(:darwin) %}

require "../client"
require "../interface_name"
require "../key"
require "../protocol/device_request"
require "./handle"

class Tunnelgeist::Client
  # A device `create` made: its handle and the utun descriptor, which goes
  # with every change, so the daemon knows the request comes from the
  # device's holder and holds the device while it changes it.
  class Device < Handle
    # The utun descriptor, owned by the caller, who closes it. It has
    # close-on-exec set and is blocking: `FdPassing.receive` leaves the
    # flags of the open file description as the daemon made it, and the
    # daemon makes it blocking.
    getter fd : Int32
    # The MTU the device was created with.
    getter mtu : Int32

    protected def initialize(client : Client, *, name : InterfaceName, key : Key, @mtu : Int32, @fd : Int32)
      super(client, name: name, key: key)
    end

    # A handle of the same device without the descriptor, which cannot
    # change the device.
    def to_handle : Handle
      Handle.new(@client, name: @name, key: @key)
    end

    # Sends *request* with the device's descriptor.
    protected def change(request : Protocol::DeviceRequest) : Nil
      @client.exchange(request, fd: @fd)
    end
  end
end
