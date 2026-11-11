# The daemon tests: a `Tunnelgeist::Client` asks the real root daemon, whose
# socket path is in TUNNELGEIST_SOCKET, for utun devices, and the kernel's
# `ifconfig`, `route` and `ping` look at them. `rake test:daemon` starts the
# daemon under sudo and runs these as the caller; plain `rake test` does not
# compile them.
require "../test_helper"
require "socket"
require "../../src/tunnelgeist/client"
require "../../src/tunnelgeist/commands"
require "../../src/tunnelgeist/fd_passing"
require "../../src/tunnelgeist/lib_system"

describe TunnelgeistDaemon do
  {% if flag?(:darwin) %}
    @files = {} of Int32 => IO::FileDescriptor
    @names = [] of Tunnelgeist::InterfaceName

    # The kernel removes a closed device's interface a moment later, and
    # the devices of one user count against its limit until then, so each
    # test waits for its devices to go before the next one starts.
    after do
      @files.each_value { |file| file.close unless file.closed? }
      @names.each { |name| wait_until { !interface?(name) } }
    end

    test "the kernel's ping arrives on the device and its route goes when removed" do
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

    test "closing the descriptor removes the device, which then cannot be changed" do
      device = create_device
      name = device.name
      open_device(device).close

      wait_until { !interface?(name) }
      assert(!interface?(name))

      # The closed number goes to the connection's socket or nowhere, so the
      # daemon refuses the descriptor or the client cannot send it.
      raised(Tunnelgeist::Client::Error) do
        device.add_route(Tunnelgeist::Prefix.parse("10.78.1.0/24"))
      end
    end

    test "a new device that takes the name of a closed one is changed with its own descriptor" do
      old = create_device
      old_name = old.name
      open_device(old).close
      wait_until { !interface?(old_name) }

      fresh = create_device(old_name)
      assert(fresh.name == old_name)

      assert(!routed_via?("10.79.2.1", name: fresh.name))
      fresh.add_route(Tunnelgeist::Prefix.parse("10.79.2.0/24"))
      assert(routed_via?("10.79.2.1", name: fresh.name))
    end

    test "a change sent with another device's descriptor is refused and changes neither" do
      first = create_device
      second = create_device
      route = Tunnelgeist::Prefix.parse("10.79.3.0/24")
      request = Tunnelgeist::Protocol::AddRoute.new(name: first.name, route: route)

      reply = reply_of(send_change(request, fd: second.fd))

      assert(reply == Tunnelgeist::Protocol::Reply.new(ok: false, error: "descriptor is #{second.name}, not #{first.name}"))
      assert(!routed_via?("10.79.3.1", name: first.name))
      assert(!routed_via?("10.79.3.1", name: second.name))
    end

    # A change against the last close of its device (RF1.3): the client
    # sends two changes of device A, each with A's descriptor, closes its
    # own copy at once and asks for a device of A's name, B, until the
    # kernel frees the name. The descriptors in flight, and then the
    # daemon's copies, keep A and its name until the daemon has made both
    # changes and closed them, so the changes land on A, go away with it,
    # and B starts without them. A daemon that found the device by its name
    # alone could run a change after A was gone and B had its name, and B
    # would get A's address or route.
    #
    # The test cannot make the daemon run its command at a chosen moment,
    # so it cannot prove the daemon's side of the race: it repeats the
    # sequence and asks for B as early as the kernel allows, which a daemon
    # that did not hold the device would fail in some runs, not in all.
    test "a change sent as the device's last descriptor closes lands on that device, not on the next of its name" do
      3.times do
        first = create_device(addresses: [ipv4_address("10.77.4.1", peer: "10.77.4.2")],
          routes: [] of Tunnelgeist::Prefix)
        name = first.name
        added = ipv4_address("10.77.5.1", peer: "10.77.5.2")
        route = Tunnelgeist::Prefix.parse("10.79.4.0/24")
        pending = [
          send_change(Tunnelgeist::Protocol::AddAddress.new(name: name, address: added), fd: first.fd),
          send_change(Tunnelgeist::Protocol::AddRoute.new(name: name, route: route), fd: first.fd),
        ]
        open_device(first).close

        second = create_when_free(name)
        replies = pending.map { |socket| reply_of(socket) }

        # The daemon held A until both changes were done, so A was still
        # registered and both went through.
        assert(replies.all?(&.ok))
        assert(second.name == name)
        assert(!address?("10.77.4.1", name: second.name))
        assert(!address?("10.77.5.1", name: second.name))
        assert(!routed_via?("10.79.4.1", name: second.name))

        open_device(second).close
        wait_until { !interface?(name) }
      end
    end

    test "the daemon keeps at most 16 devices of one user and takes a new one once one is closed" do
      bare = [] of Tunnelgeist::Address
      devices = Array.new(16) { create_device(addresses: bare, routes: [] of Tunnelgeist::Prefix) }
      before = utun_interfaces

      error = raised(Tunnelgeist::Client::Error) do
        create_device(addresses: bare, routes: [] of Tunnelgeist::Prefix)
      end

      assert(error.reason.refused?)
      assert(error.message == "device limit of 16 reached for uid #{Tunnelgeist::LibSystem.geteuid}")
      assert(utun_interfaces == before)

      closed = devices.first
      open_device(closed).close
      wait_until { !interface?(closed.name) }

      fresh = create_device(addresses: bare, routes: [] of Tunnelgeist::Prefix)
      assert(interface?(fresh.name))
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
      Tunnelgeist::Client.new(socket_path)
    end

    # The daemon's socket, from TUNNELGEIST_SOCKET.
    def socket_path : String
      ENV["TUNNELGEIST_SOCKET"]? || raise "set TUNNELGEIST_SOCKET to the daemon's socket"
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
      @names << device.name
      device
    end

    # Asks the daemon for a device named *name*, with no address and no
    # route, again and again for at most 5 s while the kernel still gives
    # the name to an interface, which makes the daemon refuse it.
    def create_when_free(name : Tunnelgeist::InterfaceName) : Tunnelgeist::Client::Device
      started = Time.instant
      loop do
        begin
          device = create_device(name, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix)
          return device
        rescue error : Tunnelgeist::Client::Error
          raise error unless error.reason.refused? && started.elapsed < 5.seconds
        end
        sleep 5.milliseconds
      end
    end

    # Sends *request* with the descriptor *fd*, as `Client::Device` does,
    # and returns the connection without waiting for the reply, so a test
    # can act while the daemon serves the request; `reply_of` reads it.
    def send_change(request : Tunnelgeist::Protocol::DeviceRequest, *, fd : Int32) : UNIXSocket
      socket = UNIXSocket.new(socket_path)
      begin
        Tunnelgeist::FdPassing.send(socket, data: "#{request.to_json}\n".to_slice, fd: fd)
      rescue error
        socket.close
        raise error
      end
      socket
    end

    # The reply the daemon sends on *socket* within 5 s; closes *socket*.
    def reply_of(socket : UNIXSocket) : Tunnelgeist::Protocol::Reply
      socket.read_timeout = 5.seconds
      Tunnelgeist::Protocol::Reply.parse(socket.gets.to_s)
    ensure
      socket.close
    end

    # 10.77.3.1/24 with the peer 10.77.3.2, inside the address rule of the
    # configuration `rake test:daemon` writes.
    def test_address : Tunnelgeist::Address
      ipv4_address("10.77.3.1", peer: "10.77.3.2")
    end

    # The IPv4 address *local*/24 with the peer *peer*.
    def ipv4_address(local : String, *, peer : String) : Tunnelgeist::Address
      Tunnelgeist::Address.new(Socket::IPAddress.new(local, 0), prefix: 24, peer: Socket::IPAddress.new(peer, 0))
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
