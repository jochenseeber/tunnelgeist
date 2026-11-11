{% skip_file unless flag?(:darwin) %}

require "socket"
require "./fd_passing/lib_socket"
require "./fd_passing/received"
require "./fd_passing/truncated_error"

module Tunnelgeist
  # Sends and receives a file descriptor together with data over a Unix
  # stream socket (`SCM_RIGHTS`). The daemon sends the utun
  # descriptor with `send`; the client library takes it with `receive`.
  module FdPassing
    extend self

    # The size in bytes of the control buffer `receive` supplies; room for
    # 509 descriptors. When a message carries more than fit, Darwin installs
    # them all but reports only those that fit, so the rest would stay open
    # and unreachable. One message carries at most 254 (sendmsg refuses
    # more as an invalid argument, checked with a C program on Darwin), and
    # a stream socket's `recvmsg` returns the control data of one message
    # only, so every descriptor that arrives is reported, and no peer can
    # leave descriptors open in the receiver.
    private CONTROL_WORDS = 512
    private CONTROL_SIZE  = CONTROL_WORDS * 4

    # Sends all of *data* in one `sendmsg`, with *fd* attached when given.
    # Waits for the socket to become writable when the kernel buffer is
    # full. Raises `IO::Error` on a failure or a short send.
    def send(socket : UNIXSocket, *, data : Bytes, fd : Int32? = nil) : Nil
      iov = LibSocket::Iovec.new(iov_base: data.to_unsafe.as(Void*), iov_len: data.size)
      message = LibSocket::Msghdr.new
      message.msg_iov = pointerof(iov)
      message.msg_iovlen = 1

      # An array of UInt32 aligns the control buffer for `cmsghdr`.
      control = StaticArray(UInt32, 4).new(0_u32)
      if fd
        write_rights(control.to_unsafe, fd: fd)
        message.msg_control = control.to_unsafe.as(Void*)
        message.msg_controllen = cmsg_space(sizeof(Int32)).to_u32
      end

      send_message(socket, message: pointerof(message), size: data.size)
    end

    # Writes one `SCM_RIGHTS` control message carrying *fd* to *control*.
    private def write_rights(control : UInt32*, *, fd : Int32) : Nil
      header = control.as(LibSocket::Cmsghdr*)
      header.value.cmsg_len = cmsg_len(sizeof(Int32)).to_u32
      header.value.cmsg_level = LibC::SOL_SOCKET
      header.value.cmsg_type = LibSocket::SCM_RIGHTS
      (control.as(UInt8*) + cmsg_data_offset).as(Int32*).value = fd
    end

    # Sends *message*, whose data is *size* bytes, in one `sendmsg`,
    # waiting while the socket is not writable. Raises `IO::Error` on a
    # failure or a short send.
    private def send_message(socket : UNIXSocket, *, message : LibSocket::Msghdr*, size : Int32) : Nil
      loop do
        sent = LibSocket.sendmsg(socket.fd, message, 0)
        if sent >= 0
          raise IO::Error.new("sendmsg: sent #{sent} of #{size} bytes", target: socket) if sent != size
          return
        end

        case Errno.value
        when Errno::EINTR
          next
        when Errno::EAGAIN
          Crystal::EventLoop.current.wait_writable(socket)
        else
          raise IO::Error.from_errno("sendmsg", target: socket)
        end
      end
    end

    # Reads into *buffer* and returns the number of bytes read (0 at end of
    # stream), the descriptor that came with them, or nil, and the number of
    # descriptors that came, as a `Received`. The descriptor has
    # close-on-exec set; descriptors beyond the first are closed, so a
    # caller that wants one can tell that more came.
    #
    # Waits for data while the socket is empty and raises `IO::TimeoutError`
    # when `socket.read_timeout` elapses first. Raises `IO::Error` on a
    # failure, and `TruncatedError` when the kernel truncated the control
    # data (the received descriptors are closed), which the size of the
    # control buffer rules out on Darwin.
    def receive(socket : UNIXSocket, *, buffer : Bytes) : Received
      iov = LibSocket::Iovec.new(iov_base: buffer.to_unsafe.as(Void*), iov_len: buffer.size)
      control = StaticArray(UInt32, CONTROL_WORDS).new(0_u32)
      message = LibSocket::Msghdr.new
      message.msg_iov = pointerof(iov)
      message.msg_iovlen = 1
      message.msg_control = control.to_unsafe.as(Void*)
      message.msg_controllen = CONTROL_SIZE.to_u32

      loop do
        count = LibSocket.recvmsg(socket.fd, pointerof(message), 0)
        if count >= 0
          descriptors = collect_descriptors(message: message, control: control.to_unsafe.as(UInt8*))
          descriptor = take_descriptor(descriptors, socket: socket, message: message)
          received = Received.new(size: count.to_i32, fd: descriptor, descriptor_count: descriptors.size)
          return received
        end

        case Errno.value
        when Errno::EINTR
          next
        when Errno::EAGAIN
          Crystal::EventLoop.current.wait_readable(socket)
        else
          raise IO::Error.from_errno("recvmsg", target: socket)
        end
      end
    end

    # The first of *descriptors*, the received control data of *message*,
    # with close-on-exec set; the others are closed. Raises when the data
    # was truncated, closing what arrived.
    private def take_descriptor(descriptors : Array(Int32), *, socket : UNIXSocket, message : LibSocket::Msghdr) : Int32?
      if (message.msg_flags & LibSocket::MSG_CTRUNC) != 0
        descriptors.each { |descriptor| LibC.close(descriptor) }
        raise TruncatedError.new("recvmsg: control data truncated", target: socket)
      end

      keep_first(descriptors, socket: socket)
    end

    # Every descriptor of the `SCM_RIGHTS` messages in *control*. Walks the
    # control messages only inside the bytes the kernel filled (the
    # `msg_controllen` of *message*, at most the buffer), and clamps every
    # message to them.
    private def collect_descriptors(*, message : LibSocket::Msghdr, control : UInt8*) : Array(Int32)
      descriptors = [] of Int32
      length = Math.min(message.msg_controllen.to_i, CONTROL_SIZE)
      offset = 0

      while (offset + sizeof(LibSocket::Cmsghdr)) <= length
        header = (control + offset).as(LibSocket::Cmsghdr*).value
        break if header.cmsg_len < sizeof(LibSocket::Cmsghdr)

        if header.cmsg_level == LibC::SOL_SOCKET && header.cmsg_type == LibSocket::SCM_RIGHTS
          available = Math.min(header.cmsg_len.to_i, length - offset) - cmsg_data_offset
          (available // sizeof(Int32)).times do |index|
            descriptors << (control + offset + cmsg_data_offset).as(Int32*)[index]
          end
        end

        offset += cmsg_align(header.cmsg_len.to_i)
      end
      descriptors
    end

    # The first of *descriptors*, with close-on-exec set; closes the others,
    # and the first too when close-on-exec cannot be set.
    private def keep_first(descriptors : Array(Int32), *, socket : UNIXSocket) : Int32?
      descriptors.skip(1).each { |descriptor| LibC.close(descriptor) }
      first = descriptors.first?
      # Darwin has no MSG_CMSG_CLOEXEC, so the descriptor is inheritable
      # between recvmsg and this call; a fork and exec by another fiber's
      # thread in that window would leak it.
      if first && LibC.fcntl(first, LibC::F_SETFD, LibC::FD_CLOEXEC) == -1
        error = Errno.value
        LibC.close(first)
        raise IO::Error.from_os_error("fcntl", error, target: socket)
      end
      first
    end

    # The `CMSG_*` arithmetic of sys/socket.h, where `__DARWIN_ALIGN32`
    # rounds up to a multiple of 4 bytes (`__DARWIN_ALIGNBYTES32` is 3).
    private def cmsg_align(size : Int32) : Int32
      (size + 3) & ~3
    end

    # `CMSG_LEN`: the `cmsg_len` of a message with *size* bytes of data.
    private def cmsg_len(size : Int32) : Int32
      cmsg_data_offset + size
    end

    # `CMSG_SPACE`: the room a message with *size* bytes of data takes.
    private def cmsg_space(size : Int32) : Int32
      cmsg_data_offset + cmsg_align(size)
    end

    # `CMSG_DATA`: the offset of the data from the message header.
    private def cmsg_data_offset : Int32
      cmsg_align(sizeof(LibSocket::Cmsghdr))
    end
  end
end
