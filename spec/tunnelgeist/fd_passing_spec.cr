require "../spec_helper"
require "../../src/tunnelgeist/fd_passing"

# `SCM_RIGHTS` descriptor passing over a Unix stream socket pair.
describe Tunnelgeist::FdPassing do
  {% if flag?(:darwin) %}
    alias LibSocket = Tunnelgeist::FdPassing::LibSocket

    # Sends *data* with every descriptor of *fds* in one control message,
    # which `FdPassing.send` itself does not do.
    def send_many(socket : UNIXSocket, *, data : Bytes, fds : Array(Int32)) : Nil
      iov = LibSocket::Iovec.new(iov_base: data.to_unsafe.as(Void*), iov_len: data.size)
      control = Bytes.new(12 + fds.size * 4)
      header = control.to_unsafe.as(LibSocket::Cmsghdr*)
      header.value.cmsg_len = control.size.to_u32
      header.value.cmsg_level = LibC::SOL_SOCKET
      header.value.cmsg_type = LibSocket::SCM_RIGHTS
      fds.each_with_index { |fd, index| (control.to_unsafe + 12).as(Int32*)[index] = fd }
      message = LibSocket::Msghdr.new
      message.msg_iov = pointerof(iov)
      message.msg_iovlen = 1
      message.msg_control = control.to_unsafe.as(Void*)
      message.msg_controllen = control.size.to_u32
      raise "sendmsg failed" if LibSocket.sendmsg(socket.fd, pointerof(message), 0) != data.size
    end

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

    test "data without a descriptor returns nil for the descriptor" do
      left, right = UNIXSocket.pair

      Tunnelgeist::FdPassing.send(left, data: "plain".to_slice)
      buffer = Bytes.new(16)
      received = Tunnelgeist::FdPassing.receive(right, buffer: buffer)
      count = received.size

      assert(String.new(buffer[0, count]) == "plain")
      assert(received.fd.nil?)
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
      assert(open_descriptors - before == 1)
      LibC.close(received.fd!)
      assert(open_descriptors == before)
    ensure
      [left, right, reader, writer].each(&.try(&.close))
    end
  {% end %}
end
