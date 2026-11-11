# The daemon tests: a `Tunnelgeist::Client` asks the real root daemon, whose
# socket path is in TUNNELGEIST_SOCKET, for utun devices, and the kernel's
# `ifconfig`, `route` and `ping` look at them. `rake test:daemon` starts the
# daemon under sudo and runs these as the caller; plain `rake test` does not
# compile them.
require "../test_helper"
require "socket"
require "../../src/tunnelgeist/client"
require "../../src/tunnelgeist/commands"

describe TunnelgeistDaemon do
  {% if flag?(:darwin) %}
    @files = {} of Int32 => IO::FileDescriptor

    after do
      @files.each_value { |file| file.close unless file.closed? }
    end

    test "the kernel's ping arrives on the device and the route follows the key's owner" do
      device = create_device
      file = open_device(device)

      # Nothing answers, so the ping's exit status is ignored.
      spawn { Process.run("/sbin/ping", ["-c1", "-t2", "10.77.3.2"], output: Process::Redirect::Close, error: Process::Redirect::Close) }

      bytes = read_ipv4_frame(file)

      assert(bytes[0, 4].to_a == [0_u8, 0_u8, 0_u8, 2_u8])
      assert((bytes[4] >> 4) == 4)
      assert(bytes[4 + 9] == 1)
      assert(bytes[20, 4].to_a == [10_u8, 77_u8, 3_u8, 2_u8])

      assert(routed_via?("10.78.0.1", name: device.name))
      device.remove_route(Tunnelgeist::Prefix.parse("10.78.0.0/16"))
      assert(!routed_via?("10.78.0.1", name: device.name))
    end

    test "closing the descriptor removes the device and the daemon refuses its key" do
      device = create_device
      name = device.name
      open_device(device).close

      wait_until { !interface?(name) }
      assert(!interface?(name))

      error = raised(Tunnelgeist::Client::Error) do
        device.add_route(Tunnelgeist::Prefix.parse("10.78.1.0/24"))
      end
      assert(error.message.to_s.includes?(Tunnelgeist::Protocol::UNKNOWN_DEVICE))
    end

    test "a new device that takes the name of a closed one is not reachable with the old key" do
      old = create_device
      old_name = old.name
      old_key = old.key
      open_device(old).close
      wait_until { !interface?(old_name) }

      fresh = create_device(old_name)
      assert(fresh.name == old_name)

      error = raised(Tunnelgeist::Client::Error) do
        client.handle(old_name, key: old_key).add_route(Tunnelgeist::Prefix.parse("10.79.2.0/24"))
      end
      assert(error.message.to_s.includes?(Tunnelgeist::Protocol::UNKNOWN_DEVICE))

      assert(!routed_via?("10.79.2.1", name: fresh.name))
      fresh.add_route(Tunnelgeist::Prefix.parse("10.79.2.0/24"))
      assert(routed_via?("10.79.2.1", name: fresh.name))
    end

    test "the daemon refuses an address outside its configuration and creates no device" do
      address = Tunnelgeist::Address.new(
        Socket::IPAddress.new("10.99.0.1", 0), prefix: 24, peer: Socket::IPAddress.new("10.99.0.2", 0))

      before = utun_interfaces

      error = raised(Tunnelgeist::Client::Error) do
        create_device(addresses: [address], routes: [] of Tunnelgeist::Prefix)
      end

      assert(error.reason.refused?)
      assert(error.message == "address 10.99.0.1/24 not allowed")
      assert(utun_interfaces == before)
    end

    test "the daemon identifies an alias by its local address and removes it by the exact record" do
      device = create_device(addresses: [] of Tunnelgeist::Address)
      first = test_address
      same_local = Tunnelgeist::Address.new(
        Socket::IPAddress.new("10.77.3.1", 0), prefix: 25, peer: Socket::IPAddress.new("10.77.3.2", 0))

      device.add_address(first)
      assert(address?("10.77.3.1", name: device.name))

      error = raised(Tunnelgeist::Client::Error) { device.add_address(same_local) }
      assert(error.reason.refused?)
      assert(error.message == "address 10.77.3.1 already on #{device.name}")

      device.remove_address(first)
      assert(!address?("10.77.3.1", name: device.name))
    end

    test "the daemon refuses a route outside its configuration and creates no device" do
      before = utun_interfaces

      error = raised(Tunnelgeist::Client::Error) do
        create_device(routes: [Tunnelgeist::Prefix.parse("10.99.0.0/16")])
      end

      assert(error.reason.refused?)
      assert(error.message == "route 10.99.0.0/16 not allowed")
      assert(utun_interfaces == before)
    end

    # Reads frames until one with the AF_INET header arrives, within one 3 s
    # deadline. The kernel also sends IPv6 housekeeping (neighbor discovery,
    # MLD) on a fresh utun, which is skipped. Fails when no IPv4 frame comes.
    def read_ipv4_frame(file : IO::FileDescriptor) : Bytes
      deadline = Time.instant + 3.seconds
      skipped = 0
      frame = Bytes.new(2_048)
      loop do
        remaining = deadline - Time.instant
        raise "no IPv4 frame within 3 s; skipped #{skipped} other frames" if remaining <= Time::Span.zero
        file.read_timeout = remaining
        count = begin
          file.read(frame)
        rescue IO::TimeoutError
          raise "no IPv4 frame within 3 s; skipped #{skipped} other frames"
        end
        bytes = frame[0, count]
        if (count >= 24) && (bytes[0, 4].to_a == [0_u8, 0_u8, 0_u8, 2_u8])
          result = bytes.dup
          return result
        end
        skipped += 1
      end
    end

    def client : Tunnelgeist::Client
      Tunnelgeist::Client.new(ENV["TUNNELGEIST_SOCKET"]? || raise "set TUNNELGEIST_SOCKET to the daemon's socket")
    end

    # The wrapper of the device's descriptor, made by `create_device`; closing
    # it closes the descriptor.
    def open_device(device : Tunnelgeist::Client::Device) : IO::FileDescriptor
      @files[device.fd]
    end

    # Asks the daemon for a device with *addresses*, by default 10.77.3.1/24
    # (peer 10.77.3.2), and *routes*, by default 10.78.0.0/16, and wraps its
    # descriptor so `after` closes it, also when a test expected a refusal
    # and got a device. The wrapper reads without buffering, so one `read` is
    # one frame.
    def create_device(name : Tunnelgeist::InterfaceName? = nil, *,
                      addresses : Array(Tunnelgeist::Address) = [test_address],
                      routes : Array(Tunnelgeist::Prefix) = [Tunnelgeist::Prefix.parse("10.78.0.0/16")]) : Tunnelgeist::Client::Device
      device = client.create(name, addresses: addresses, routes: routes)
      file = IO::FileDescriptor.new(device.fd)
      file.read_timeout = 3.seconds
      file.read_buffering = false
      @files[device.fd] = file
      device
    end

    # 10.77.3.1/24 with the peer 10.77.3.2, inside the address rule of the
    # configuration `rake test:daemon` writes.
    def test_address : Tunnelgeist::Address
      Tunnelgeist::Address.new(
        Socket::IPAddress.new("10.77.3.1", 0), prefix: 24, peer: Socket::IPAddress.new("10.77.3.2", 0))
    end

    # Whether `route -n get` sends *destination* out of the interface *name*.
    def routed_via?(destination : String, *, name : Tunnelgeist::InterfaceName) : Bool
      Tunnelgeist::Commands.routes_to?(route_get(destination), name: name)
    end

    def route_get(destination : String) : String
      output = IO::Memory.new
      Process.run("/sbin/route", ["-n", "get", destination], output: output, error: output)
      output.to_s
    end

    # Whether `ifconfig` lists *address* on the interface *name*.
    def address?(address : String, *, name : Tunnelgeist::InterfaceName) : Bool
      output = IO::Memory.new
      Process.run("/sbin/ifconfig", [name.to_s], output: output, error: output)
      output.to_s.split.includes?(address)
    end

    # The names of the utun interfaces the kernel has, from `ifconfig -l`, so
    # a test can tell that a refused request left no device behind.
    def utun_interfaces : Array(String)
      output = IO::Memory.new
      status = Process.run("/sbin/ifconfig", ["-l"], output: output)
      raise "ifconfig -l failed: #{status}" unless status.success?

      output.to_s.split.select(&.starts_with?("utun")).sort!
    end

    def interface?(name : Tunnelgeist::InterfaceName) : Bool
      Process.run("/sbin/ifconfig", [name.to_s], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
    end

    # The daemon learns of a departure from an asynchronous kernel event.
    def wait_until(timeout : Time::Span = 2.seconds, &condition : -> Bool) : Nil
      started = Time.instant
      until condition.call
        return if started.elapsed > timeout
        sleep 20.milliseconds
      end
    end
  {% end %}
end
