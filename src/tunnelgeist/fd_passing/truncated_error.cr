{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  module FdPassing
    # The kernel cut the control data of a received message short: more
    # descriptors came than `FdPassing.receive` has room for. The
    # descriptors that arrived are closed.
    class TruncatedError < IO::Error
    end
  end
end
