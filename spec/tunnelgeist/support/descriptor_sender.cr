require "socket"
require "../../../src/tunnelgeist/fd_passing/lib_socket"

# Sends several descriptors in one message, which `FdPassing.send` itself
# does not do, so a spec can check what a receiver does with them.
module TunnelgeistDescriptorSender
  {% if flag?(:darwin) %}
    extend self

    # Sends *data* with every descriptor of *fds* in one `SCM_RIGHTS`
    # control message, in one `sendmsg`; without descriptors, with no
    # control message. Raises when the kernel takes less than all of *data*.
    def send_many(socket : UNIXSocket, *, data : Bytes, fds : Array(Int32)) : Nil
      iov = Tunnelgeist::FdPassing::LibSocket::Iovec.new(iov_base: data.to_unsafe.as(Void*), iov_len: data.size)
      # The data of a control message starts 12 bytes after its header
      # (`CMSG_DATA`).
      control = Bytes.new(12 + fds.size * 4)
      header = control.to_unsafe.as(Tunnelgeist::FdPassing::LibSocket::Cmsghdr*)
      header.value.cmsg_len = control.size.to_u32
      header.value.cmsg_level = LibC::SOL_SOCKET
      header.value.cmsg_type = Tunnelgeist::FdPassing::LibSocket::SCM_RIGHTS
      fds.each_with_index { |fd, index| (control.to_unsafe + 12).as(Int32*)[index] = fd }
      message = Tunnelgeist::FdPassing::LibSocket::Msghdr.new
      message.msg_iov = pointerof(iov)
      message.msg_iovlen = 1
      unless fds.empty?
        message.msg_control = control.to_unsafe.as(Void*)
        message.msg_controllen = control.size.to_u32
      end
      sent = Tunnelgeist::FdPassing::LibSocket.sendmsg(socket.fd, pointerof(message), 0)
      raise IO::Error.from_errno("sendmsg") if sent < 0
      raise IO::Error.new("sendmsg: sent #{sent} of #{data.size} bytes") if sent != data.size
    end
  {% end %}
end
