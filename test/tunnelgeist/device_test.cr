require "../test_helper"
require "socket"
require "../../src/tunnelgeist/device"
require "../../src/tunnelgeist/device/lib_utun"

# How `Device.name_of` tells a utun descriptor by its kernel control
# address, for descriptors that are no utun device. A utun device needs
# root; the daemon tests use real ones.
describe TunnelgeistDevice do
  {% if flag?(:darwin) %}
    alias LibUtun = Tunnelgeist::Device::LibUtun

    # A socket connected to the kernel control *name*, which must accept an
    # unprivileged connection; the caller closes it.
    def kernel_control(name : String) : Int32
      fd = LibC.socket(LibUtun::PF_SYSTEM, LibC::SOCK_DGRAM, LibUtun::SYSPROTO_CONTROL)
      raise IO::Error.from_errno("socket") if fd < 0

      info = LibUtun::CtlInfo.new
      control_name = StaticArray(UInt8, LibUtun::MAX_KCTL_NAME).new(0_u8)
      name.to_slice.copy_to(control_name.to_slice)
      info.ctl_name = control_name
      raise IO::Error.from_errno("CTLIOCGINFO #{name}") if LibUtun.ioctl(fd, LibUtun::CTLIOCGINFO, pointerof(info)) < 0

      address = LibUtun::SockaddrCtl.new
      address.sc_len = sizeof(LibUtun::SockaddrCtl).to_u8
      address.sc_family = LibUtun::AF_SYSTEM.to_u8
      address.ss_sysaddr = LibUtun::AF_SYS_CONTROL.to_u16
      address.sc_id = info.ctl_id
      if LibC.connect(fd, pointerof(address).as(LibC::Sockaddr*), sizeof(LibUtun::SockaddrCtl)) < 0
        raise IO::Error.from_errno("connect #{name}")
      end
      fd
    end

    test "name_of refuses a kernel control socket of another control" do
      # The source address selection control, which any user may connect to.
      fd = kernel_control("com.apple.netsrc")
      begin
        error = raised(IO::Error) { Tunnelgeist::Device.name_of(fd) }
        assert(error.message.to_s.includes?("not #{LibUtun::UTUN_CONTROL_NAME}"))
      ensure
        LibC.close(fd)
      end
    end

    test "name_of refuses the end of a Unix socket pair by its address family" do
      left, right = UNIXSocket.pair
      begin
        error = raised(IO::Error) { Tunnelgeist::Device.name_of(left.fd) }
        assert(error.message.to_s.includes?("not a kernel control socket"))
      ensure
        left.close
        right.close
      end
    end

    test "name_of refuses a pipe and an unconnected UDP socket with the kernel's error" do
      reader, writer = IO.pipe
      udp = UDPSocket.new
      begin
        [writer.fd, udp.fd].each do |fd|
          error = raised(IO::Error) { Tunnelgeist::Device.name_of(fd) }
          assert(error.message.to_s.starts_with?("getpeername"))
          assert(error.os_error)
        end
      ensure
        reader.close
        writer.close
        udp.close
      end
    end
  {% end %}
end
