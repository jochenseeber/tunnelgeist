require "../spec_helper"
require "../../src/tunnelgeist/fd_passing"
require "./support/descriptor_sender"

# `SCM_RIGHTS` descriptor passing over a Unix stream socket pair.
describe Tunnelgeist::FdPassing do
  {% if flag?(:darwin) %}
    include TunnelgeistDescriptorSender

    # The most descriptors one message carries on Darwin: sendmsg refuses
    # more as an invalid argument (checked with a C program).
    MESSAGE_DESCRIPTORS = 254
    # The most descriptor numbers `free_descriptors` looks at.
    DESCRIPTOR_SCAN = 65_536

    # Whether *reader*, a pipe's read end with nothing written to it, is at
    # end of file, that is every copy of the write end is closed. Does not
    # wait: a write end still open makes the read fail with EAGAIN.
    def end_of_file?(reader : IO::FileDescriptor) : Bool
      LibC.fcntl(reader.fd, LibC::F_SETFL, LibC.fcntl(reader.fd, LibC::F_GETFL) | LibC::O_NONBLOCK)
      LibC.read(reader.fd, Bytes.new(1), 1) == 0
    end

    # How many more descriptors this process may open under its soft limit.
    # Numbers past `DESCRIPTOR_SCAN` count as free, which only matters when
    # the limit is far above what a message carries.
    def free_descriptors : Int32
      raise IO::Error.from_errno("getrlimit") unless LibC.getrlimit(LibC::RLIMIT_NOFILE, out limit) == 0

      scanned = Math.min(limit.rlim_cur, DESCRIPTOR_SCAN.to_u64).to_i
      open = (0...scanned).count { |fd| LibC.fcntl(fd, LibC::F_GETFD) != -1 }
      Math.min(limit.rlim_cur - open, Int32::MAX.to_u64).to_i
    end

    test "a pipe descriptor sent with data arrives open and usable" do
      left, right = UNIXSocket.pair
      reader, writer = IO.pipe

      Tunnelgeist::FdPassing.send(left, data: "hi\n".to_slice, fd: writer.fd)
      buffer = Bytes.new(16)
      received = Tunnelgeist::FdPassing.receive(right, buffer: buffer)
      count = received.size

      assert(count == 3)
      assert(String.new(buffer[0, count]) == "hi\n")
      assert(received.fd)
      assert(received.descriptor_count == 1)

      fd = received.fd!
      assert(fd != writer.fd)
      flags = LibC.fcntl(fd, LibC::F_GETFD)
      assert((flags & LibC::FD_CLOEXEC) != 0)

      IO::FileDescriptor.new(fd).tap do |through|
        through.puts("through")
        through.close
      end
      writer.close

      assert(reader.gets == "through")
    ensure
      left.try(&.close)
      right.try(&.close)
      reader.try(&.close)
      writer.try(&.close)
    end

    test "fd! raises when no descriptor came with the data" do
      received = Tunnelgeist::FdPassing::Received.new(size: 3, fd: nil)

      raised(NilAssertionError) { received.fd! }
      assert(Tunnelgeist::FdPassing::Received.new(size: 3, fd: 7).fd! == 7)
    end

    test "a Received made without a descriptor count counts its descriptor" do
      assert(Tunnelgeist::FdPassing::Received.new(size: 3, fd: nil).descriptor_count == 0)
      assert(Tunnelgeist::FdPassing::Received.new(size: 3, fd: 7).descriptor_count == 1)
    end

    test "data without a descriptor returns nil for the descriptor" do
      left, right = UNIXSocket.pair

      Tunnelgeist::FdPassing.send(left, data: "plain".to_slice)
      buffer = Bytes.new(16)
      received = Tunnelgeist::FdPassing.receive(right, buffer: buffer)
      count = received.size

      assert(String.new(buffer[0, count]) == "plain")
      assert(received.fd.nil?)
      assert(received.descriptor_count == 0)
    ensure
      left.try(&.close)
      right.try(&.close)
    end

    test "receive times out with IO::TimeoutError when nothing arrives" do
      left, right = UNIXSocket.pair
      right.read_timeout = 50.milliseconds

      raised(IO::TimeoutError) do
        Tunnelgeist::FdPassing.receive(right, buffer: Bytes.new(16))
      end
    ensure
      left.try(&.close)
      right.try(&.close)
    end

    test "of several descriptors the first is returned and the others are closed" do
      left, right = UNIXSocket.pair
      first_reader, first_writer = IO.pipe
      second_reader, second_writer = IO.pipe

      send_many(left, data: "x".to_slice, fds: [first_writer.fd, second_writer.fd])
      first_writer.close
      second_writer.close
      received = Tunnelgeist::FdPassing.receive(right, buffer: Bytes.new(4))
      count = received.size

      assert(count == 1)
      assert(received.fd)
      assert(received.descriptor_count == 2)
      # The second writer's last copy was closed by receive, so its reader
      # sees end of file; the first one is still held open by *received*.
      assert(end_of_file?(second_reader))
      assert(!end_of_file?(first_reader))
      LibC.close(received.fd!)
      assert(end_of_file?(first_reader))
    ensure
      [left, right, first_reader, first_writer, second_reader, second_writer].each(&.try(&.close))
    end

    test "as many descriptors as one message carries all arrive, and all but the first are closed" do
      left, right = UNIXSocket.pair
      reader, writer = IO.pipe
      # The kernel installs one descriptor per copy, so the burst must fit
      # the free descriptors, with one to spare for the receiving buffer.
      burst = Math.min(MESSAGE_DESCRIPTORS, free_descriptors - 1)
      raise "only #{burst} descriptors free; the spec needs more than the 13 the old buffer held" if burst <= 13

      send_many(left, data: "x".to_slice, fds: Array.new(burst, writer.fd))
      received = Tunnelgeist::FdPassing.receive(right, buffer: Bytes.new(4))
      LibC.close(received.fd!)
      writer.close

      # A control buffer too small for them would make the kernel install
      # every descriptor but report only those that fit, and the rest would
      # keep the pipe's write end open, so its reader would see no end of
      # file.
      assert(received.descriptor_count == burst)
      assert(end_of_file?(reader))
    ensure
      [left, right, reader, writer].each(&.try(&.close))
    end
  {% end %}
end
