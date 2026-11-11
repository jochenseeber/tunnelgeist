{% skip_file unless flag?(:darwin) %}

require "../interface_name"
require "../key"
require "./handle"

class Tunnelgeist::Client
  # A device `create` made: its handle and the utun descriptor.
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

    # A handle that reaches the same device without the descriptor.
    def to_handle : Handle
      Handle.new(@client, name: @name, key: @key)
    end
  end
end
