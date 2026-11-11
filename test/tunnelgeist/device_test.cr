require "../test_helper"
require "socket"
require "../../src/tunnelgeist/device"

# The interface name of a descriptor, read from the kernel with
# `UTUN_OPT_IFNAME`, for descriptors that are no utun device. A utun device
# needs root; the daemon tests read the name of real ones.
describe TunnelgeistDevice do
  {% if flag?(:darwin) %}
    test "name_of refuses the end of a Unix socket pair, which answers the option with a process id" do
      left, right = UNIXSocket.pair
      begin
        # A Unix socket takes the option for LOCAL_PEERPID, which has the
        # same number, and answers 4 bytes that are no utun name.
        error = raised(IO::Error) { Tunnelgeist::Device.name_of(left.fd) }
        assert(error.message.to_s.includes?("not a utun name"))
      ensure
        left.close
        right.close
      end
    end

    test "name_of refuses a pipe and a UDP socket with the kernel's error" do
      reader, writer = IO.pipe
      udp = UDPSocket.new
      begin
        [writer.fd, udp.fd].each do |fd|
          error = raised(IO::Error) { Tunnelgeist::Device.name_of(fd) }
          assert(error.message.to_s.starts_with?("UTUN_OPT_IFNAME"))
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
