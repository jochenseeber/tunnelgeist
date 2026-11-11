{% skip_file unless flag?(:darwin) %}

require "./device/control_lookup_error"
require "./device/lib_utun"
require "./device/utun"
require "./interface_name"

module Tunnelgeist
  # Opens the kernel side of a utun device, and tells which utun device a
  # descriptor belongs to: the daemon creates devices with it and checks the
  # descriptors clients send, and `Client#device` names a device from a
  # descriptor the process received.
  module Device
    extend self

    # The id of the utun kernel control on this boot, looked up on first
    # use by `name_of`.
    @@utun_control_id : UInt32? = nil

    # The MTU of a new device unless told otherwise, and the least the
    # protocol accepts: the minimum MTU of IPv6.
    DEFAULT_MTU = 1_280

    # Creates a utun device and returns its connected socket and the
    # interface name the kernel assigned as a `Utun`. Without *name* the
    # kernel picks the first free `utunN`; with *name* `utunN` it creates
    # that one or fails. The descriptor is blocking, has close-on-exec set
    # and the interface has MTU *mtu*; the interface is left down and
    # without addresses. The descriptor is closed on any failure.
    #
    # Raises `ArgumentError` when *mtu* is under 1, and `IO::Error` with the
    # system's message when the process is not root (EPERM at the connect),
    # the unit is taken (EBUSY) or the kernel refuses the MTU.
    def create(name : InterfaceName? = nil, *, mtu : Int32 = DEFAULT_MTU) : Utun
      # The `sc_unit` of the control address: 0 lets the kernel pick, N + 1
      # asks for `utunN`.
      unit = name ? name.unit + 1 : 0_u32
      raise ArgumentError.new("mtu must be at least 1, got #{mtu}") if mtu < 1

      fd = LibC.socket(LibUtun::PF_SYSTEM, LibC::SOCK_DGRAM, LibUtun::SYSPROTO_CONTROL)
      raise IO::Error.from_errno("Cannot open a #{LibUtun::UTUN_CONTROL_NAME} socket") if fd < 0

      begin
        mark_close_on_exec(fd)
        connect(fd, unit: unit)
        assigned = interface_name(fd)
        set_mtu(assigned, mtu: mtu)
      rescue ex
        LibC.close(fd)
        raise ex
      end

      Utun.new(fd: fd, name: assigned)
    end

    # Sets FD_CLOEXEC on *fd*: macOS has no SOCK_CLOEXEC, so a child
    # process spawned between `socket` and here would inherit the device.
    private def mark_close_on_exec(fd : Int32) : Nil
      if LibC.fcntl(fd, LibC::F_SETFD, LibC::FD_CLOEXEC) < 0
        raise IO::Error.from_errno("Cannot set close-on-exec on the #{LibUtun::UTUN_CONTROL_NAME} socket")
      end
    end

    # Looks up the id of the utun control and connects *fd* to it at
    # *unit*, which creates the interface.
    private def connect(fd : Int32, *, unit : UInt32) : Nil
      address = LibUtun::SockaddrCtl.new
      address.sc_len = sizeof(LibUtun::SockaddrCtl).to_u8
      address.sc_family = LibUtun::AF_SYSTEM.to_u8
      address.ss_sysaddr = LibUtun::AF_SYS_CONTROL.to_u16
      address.sc_id = control_id(fd)
      address.sc_unit = unit
      if LibC.connect(fd, pointerof(address).as(LibC::Sockaddr*), sizeof(LibUtun::SockaddrCtl)) < 0
        target = unit == 0 ? "a new utun" : "utun#{unit - 1}"
        raise IO::Error.from_errno("Cannot connect to #{LibUtun::UTUN_CONTROL_NAME} for #{target} (root required)")
      end
    end

    # The name of the utun device whose control socket is *fd*, from the
    # socket's peer address. The address must be the kernel control address
    # (`sockaddr_ctl`) of the utun control, by its id, which `CTLIOCGINFO`
    # gives without privileges; its unit N + 1 names `utunN`. The kernel
    # sets that address when the socket connects, so no other socket, a
    # kernel control of another kind included, passes. The daemon checks
    # with it which device a descriptor a client sent belongs to.
    #
    # Raises `IO::Error` when *fd* is no connected utun control socket: with
    # the system's message when `getpeername` fails (a pipe, an unconnected
    # socket), and saying why the address is not a utun's otherwise. Raises
    # `ControlLookupError` when the utun control's id cannot be looked up,
    # which is no fault of *fd*.
    def name_of(fd : Int32) : InterfaceName
      address = LibUtun::SockaddrCtl.new
      size = LibC::SocklenT.new(sizeof(LibUtun::SockaddrCtl))
      if LibC.getpeername(fd, pointerof(address).as(LibC::Sockaddr*), pointerof(size)) < 0
        raise IO::Error.from_errno("getpeername")
      end
      unless size >= sizeof(LibUtun::SockaddrCtl) && address.sc_family == LibUtun::AF_SYSTEM && address.ss_sysaddr == LibUtun::AF_SYS_CONTROL
        raise IO::Error.new("descriptor is not a kernel control socket")
      end
      unless address.sc_id == utun_control_id
        raise IO::Error.new("kernel control #{address.sc_id} is not #{LibUtun::UTUN_CONTROL_NAME}")
      end
      raise IO::Error.new("#{LibUtun::UTUN_CONTROL_NAME} unit 0 names no utun") if address.sc_unit == 0

      InterfaceName.new("utun#{address.sc_unit - 1}")
    end

    # The id of the utun control, looked up once on a socket of its own.
    # Raises `ControlLookupError` when the lookup fails.
    private def utun_control_id : UInt32
      @@utun_control_id ||= begin
        fd = LibC.socket(LibUtun::PF_SYSTEM, LibC::SOCK_DGRAM, LibUtun::SYSPROTO_CONTROL)
        raise IO::Error.from_errno("Cannot open a #{LibUtun::UTUN_CONTROL_NAME} socket") if fd < 0

        begin
          control_id(fd)
        ensure
          LibC.close(fd)
        end
      rescue error : IO::Error
        raise ControlLookupError.new(error.message, cause: error)
      end
    end

    # The id of the utun control, from `CTLIOCGINFO` on the kernel control
    # socket *fd*.
    private def control_id(fd : Int32) : UInt32
      info = LibUtun::CtlInfo.new
      name = StaticArray(UInt8, LibUtun::MAX_KCTL_NAME).new(0_u8)
      LibUtun::UTUN_CONTROL_NAME.to_slice.copy_to(name.to_slice)
      info.ctl_name = name
      if LibUtun.ioctl(fd, LibUtun::CTLIOCGINFO, pointerof(info)) < 0
        raise IO::Error.from_errno("CTLIOCGINFO #{LibUtun::UTUN_CONTROL_NAME}")
      end

      info.ctl_id
    end

    # Reads the name of the interface the connect of `create` made with
    # `UTUN_OPT_IFNAME`.
    private def interface_name(fd : Int32) : InterfaceName
      buffer = StaticArray(UInt8, LibUtun::IFNAMSIZ).new(0_u8)
      size = LibC::SocklenT.new(LibUtun::IFNAMSIZ)
      if LibC.getsockopt(fd, LibUtun::SYSPROTO_CONTROL, LibUtun::UTUN_OPT_IFNAME, buffer.to_unsafe.as(Void*), pointerof(size)) < 0
        raise IO::Error.from_errno("UTUN_OPT_IFNAME")
      end

      bytes = buffer.to_slice[0, Math.min(size.to_i, LibUtun::IFNAMSIZ)]
      text = String.new(bytes[0, bytes.index(0_u8) || bytes.size])
      InterfaceName.parse?(text) || raise IO::Error.new("UTUN_OPT_IFNAME gave #{text.inspect}, not a utun name")
    end

    # Sets the MTU of interface *name* with SIOCSIFMTU on a throwaway
    # socket, so the kernel sends no packet larger than *mtu*.
    private def set_mtu(name : InterfaceName, *, mtu : Int32) : Nil
      socket = LibC.socket(LibC::AF_INET, LibC::SOCK_DGRAM, 0)
      raise IO::Error.from_errno("Cannot open a socket to set the MTU of #{name}") if socket < 0

      begin
        request = LibUtun::Ifreq.new
        name_bytes = StaticArray(UInt8, LibUtun::IFNAMSIZ).new(0_u8)
        name.to_s.to_slice.copy_to(name_bytes.to_slice)
        request.name = name_bytes
        data = LibUtun::IfreqData.new
        data.mtu = mtu
        request.data = data
        if LibUtun.ioctl(socket, LibUtun::SIOCSIFMTU, pointerof(request)) < 0
          raise IO::Error.from_errno("SIOCSIFMTU #{mtu} on #{name}")
        end
      ensure
        LibC.close(socket)
      end
    end
  end
end
