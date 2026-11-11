{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  module FdPassing
    # What `FdPassing.receive` read: the number of bytes (0 at end of stream),
    # the descriptor that came with them, if any, and how many descriptors
    # came, of which `receive` closed all but *fd*. The caller closes the
    # descriptor.
    record Received, size : Int32, fd : Int32?, descriptor_count : Int32 do
      # What `receive` read when at most *fd* came: one descriptor is
      # counted for *fd*, none without it.
      def self.new(*, size : Int32, fd : Int32?) : Received
        new(size: size, fd: fd, descriptor_count: fd ? 1 : 0)
      end

      # The descriptor; raises when none came with the data.
      def fd! : Int32
        fd || raise NilAssertionError.new("no descriptor came with the data")
      end
    end
  end
end
