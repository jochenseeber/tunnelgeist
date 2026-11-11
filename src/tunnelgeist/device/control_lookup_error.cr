{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  module Device
    # The lookup of the utun control's id failed: the process could not
    # open a kernel control socket or `CTLIOCGINFO` refused. It says nothing
    # about the descriptor `Device.name_of` was asked about, so the daemon
    # logs it as its own failure.
    class ControlLookupError < IO::Error
    end
  end
end
