{% skip_file unless flag?(:darwin) %}

require "../device/lib_utun"

module Tunnelgeist
  class DepartureWatcher
    # Kernel events, which the departure watcher (UA5, UA6) reads to learn
    # that an interface went away. macOS has no `RTM_IFANNOUNCE` on its routing
    # socket, so these take its place. `PF_SYSTEM`, `IFNAMSIZ` and `ioctl` come
    # from `Device::LibUtun`. Values from the macOS SDK headers
    # (`xcrun --show-sdk-path`, then `usr/include/...`), checked against a C
    # program built with the SDK: `struct kev_request` is 12 bytes, the header
    # of `struct kern_event_msg` (`KEV_MSG_HEADER_SIZE`, up to `event_data`) 24,
    # `struct net_event_data` 24 with `if_unit` at offset 4 and `if_name` at 8,
    # and `SIOCSKEVFILT` 0x800c6502.
    lib LibKernelEvent
      # The kernel events protocol of `PF_SYSTEM` (sys/sys_domain.h).
      SYSPROTO_EVENT = 1
      # `_IOW('e', 2, struct kev_request)`: sets the vendor, class and
      # subclass a kernel event socket receives (sys/kern_event.h, encoded
      # with sys/ioccom.h).
      SIOCSKEVFILT = 0x800c6502_u64
      # Apple's vendor code and its network class (sys/kern_event.h).
      KEV_VENDOR_APPLE  = 1_u32
      KEV_NETWORK_CLASS = 1_u32
      # The data link subclass of the network class and its interface events
      # (net/net_kev.h).
      KEV_DL_SUBCLASS     =  2_u32
      KEV_DL_IF_ATTACHED  =  9_u32
      KEV_DL_IF_DETACHING = 10_u32
      KEV_DL_IF_DETACHED  = 11_u32
      # The size of a kernel event header, `offsetof(struct kern_event_msg,
      # event_data)` (sys/kern_event.h).
      KEV_MSG_HEADER_SIZE = 24

      # `struct kev_request` (sys/kern_event.h): the filter of `SIOCSKEVFILT`.
      struct KevRequest
        vendor_code : UInt32
        kev_class : UInt32
        kev_subclass : UInt32
      end

      # The header of `struct kern_event_msg` (sys/kern_event.h); the event data
      # words follow it.
      struct KernEventHeader
        total_size : UInt32
        vendor_code : UInt32
        kev_class : UInt32
        kev_subclass : UInt32
        id : UInt32
        event_code : UInt32
      end

      # `struct net_event_data` (net/if_var.h): the data of a data link event.
      # The interface name is `if_name` (NUL-terminated) followed by `if_unit`.
      struct NetEventData
        if_family : UInt32
        if_unit : UInt32
        if_name : StaticArray(UInt8, Device::LibUtun::IFNAMSIZ)
      end
    end
  end
end
