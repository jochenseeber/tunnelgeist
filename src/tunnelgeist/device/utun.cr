{% skip_file unless flag?(:darwin) %}

require "../interface_name"

module Tunnelgeist
  module Device
    # A utun device `Device.create` opened: its connected socket and the
    # interface name the kernel assigned. The caller closes *fd*.
    record Utun, fd : Int32, name : InterfaceName
  end
end
