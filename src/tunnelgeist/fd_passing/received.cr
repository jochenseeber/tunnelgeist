{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  module FdPassing
    # What `FdPassing.receive` read: the number of bytes (0 at end of stream)
    # and the descriptor that came with them, if any. The caller closes
    # the descriptor.
    record Received, size : Int32, fd : Int32? do
      # The descriptor; raises when none came with the data.
      def fd! : Int32
        fd || raise NilAssertionError.new("no descriptor came with the data")
      end
    end
  end
end
