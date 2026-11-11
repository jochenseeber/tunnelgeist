require "../spec_helper"
require "../../src/tunnelgeist/fd_passing"
require "./support/descriptor_sender"

# `SCM_RIGHTS` descriptor passing over a Unix stream socket pair.
describe Tunnelgeist::FdPassing do
  {% if flag?(:darwin) %}
    include TunnelgeistDescriptorSender

    # The descriptors currently open in this process.
    def open_descriptors : Int32
      (0...1_024).count { |fd| LibC.fcntl(fd, LibC::F_GETFD) != -1 }
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
      assert(second_reader.read(Bytes.new(1)) == 0)
      LibC.close(received.fd!)
      assert(first_reader.read(Bytes.new(1)) == 0)
    ensure
      [left, right, first_reader, first_writer, second_reader, second_writer].each(&.try(&.close))
    end

    test "200 descriptors in one message all arrive, and all but the first are closed" do
      left, right = UNIXSocket.pair
      reader, writer = IO.pipe
      before = open_descriptors

      # Darwin lets one message carry up to 254 (sendmsg refuses more as an
      # invalid argument, checked with a C program); 200 stays under a soft
      # limit of 256 open descriptors. The kernel installs one descriptor per
      # copy.
      send_many(left, data: "x".to_slice, fds: Array.new(200, writer.fd))
      received = Tunnelgeist::FdPassing.receive(right, buffer: Bytes.new(4))

      # A control buffer too small for them would make the kernel install
      # every descriptor but report only those that fit, and the rest would
      # stay open and unreachable.
      assert(received.descriptor_count == 200)
      assert(open_descriptors - before == 1)
      LibC.close(received.fd!)
      assert(open_descriptors == before)
    ensure
      [left, right, reader, writer].each(&.try(&.close))
    end
  {% end %}
end
