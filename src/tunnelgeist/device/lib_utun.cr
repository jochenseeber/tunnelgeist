{% skip_file unless flag?(:darwin) %}

require "c/sys/socket"
require "c/sys/types"

module Tunnelgeist
  module Device
    # The macOS declarations `Tunnelgeist::Device` needs and the standard
    # library's `LibC` lacks. Values from the macOS SDK headers
    # (`xcrun --show-sdk-path`, then `usr/include/...`), and the sizes and ioctl
    # numbers checked against a C program built with that SDK:
    # `struct ctl_info` is 100 bytes, `struct sockaddr_ctl` 32, `struct ifreq`
    # 32 with `ifr_mtu` at offset 16.
    lib LibUtun
      # The kernel event and control domain (sys/socket.h: `AF_SYSTEM`,
      # `PF_SYSTEM`).
      AF_SYSTEM = 32
      PF_SYSTEM = AF_SYSTEM
      # The kernel control protocol of `PF_SYSTEM` and its address subtype
      # (sys/sys_domain.h).
      SYSPROTO_CONTROL = 2
      AF_SYS_CONTROL   = 2
      # `_IOWR('N', 3, struct ctl_info)`: looks up a kernel control's id by name
      # (sys/kern_control.h, encoded with sys/ioccom.h).
      CTLIOCGINFO = 0xc0644e03_u64
      # The size of `ctl_info.ctl_name` (sys/kern_control.h).
      MAX_KCTL_NAME = 96
      # The kernel control that creates utun interfaces (net/if_utun.h).
      UTUN_CONTROL_NAME = "com.apple.net.utun_control"
      # The socket option that reads the interface name (net/if_utun.h).
      UTUN_OPT_IFNAME = 2
      # `_IOW('i', 52, struct ifreq)`: sets an interface's MTU through a socket
      # (sys/sockio.h).
      SIOCSIFMTU = 0x80206934_u64

      # The size of an interface name buffer, terminating NUL included
      # (net/if.h).
      IFNAMSIZ = 16

      # `struct ctl_info` (sys/kern_control.h).
      struct CtlInfo
        ctl_id : UInt32
        ctl_name : StaticArray(UInt8, MAX_KCTL_NAME)
      end

      # `struct sockaddr_ctl` (sys/kern_control.h).
      struct SockaddrCtl
        sc_len : ::LibC::UChar
        sc_family : ::LibC::UChar
        ss_sysaddr : UInt16
        sc_id : UInt32
        sc_unit : UInt32
        sc_reserved : StaticArray(UInt32, 5)
      end

      # The union `ifr_ifru` of `struct ifreq` (net/if.h), with the member this
      # shard uses plus a `struct sockaddr` and a pointer, so the size (16) and
      # alignment (8) match.
      union IfreqData
        mtu : ::LibC::Int
        addr : ::LibC::Sockaddr
        data : Void*
      end

      # `struct ifreq` (net/if.h): the interface name, then the union.
      struct Ifreq
        name : StaticArray(UInt8, IFNAMSIZ)
        data : IfreqData
      end

      fun ioctl(fd : ::LibC::Int, request : ::LibC::ULong, ...) : ::LibC::Int
    end
  end
end
