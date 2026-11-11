{% skip_file unless flag?(:darwin) %}

require "c/sys/socket"
require "c/sys/types"

module Tunnelgeist
  module FdPassing
    # The macOS declarations `Tunnelgeist::FdPassing` needs and the standard
    # library's `LibC` lacks. Values from the macOS SDK headers
    # (`xcrun --show-sdk-path`, then `usr/include/...`), and the sizes checked
    # against a C program built with that SDK: `struct msghdr` is 48 bytes
    # (`msg_iov` at 16, `msg_control` at 32, `msg_controllen` at 40),
    # `struct cmsghdr` 12 (`cmsg_level` at 4, `cmsg_type` at 8) and
    # `CMSG_LEN(4)` is 16.
    lib LibSocket
      # The control message type that carries file descriptors (sys/socket.h).
      SCM_RIGHTS = 1
      # `recvmsg` flag: the control data did not fit the buffer (sys/socket.h).
      MSG_CTRUNC = 0x20

      # `struct iovec` (sys/_types/_iovec_t.h).
      struct Iovec
        iov_base : Void*
        iov_len : ::LibC::SizeT
      end

      # `struct msghdr` (sys/socket.h).
      struct Msghdr
        msg_name : Void*
        msg_namelen : UInt32
        msg_iov : Iovec*
        msg_iovlen : ::LibC::Int
        msg_control : Void*
        msg_controllen : UInt32
        msg_flags : ::LibC::Int
      end

      # `struct cmsghdr` (sys/socket.h); its data follows at offset 12
      # (`CMSG_DATA`).
      struct Cmsghdr
        cmsg_len : UInt32
        cmsg_level : ::LibC::Int
        cmsg_type : ::LibC::Int
      end

      fun sendmsg(fd : ::LibC::Int, message : Msghdr*, flags : ::LibC::Int) : ::LibC::SSizeT
      fun recvmsg(fd : ::LibC::Int, message : Msghdr*, flags : ::LibC::Int) : ::LibC::SSizeT
    end
  end
end
