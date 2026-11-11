require "../spec_helper"
require "../../src/tunnelgeist/handler"
require "../../src/tunnelgeist/client"
require "./support/client_configs"
require "./support/temporary_directory"

# The client library `Tunnelgeist::Client` (TA2) against the real `Handler`,
# served on a Unix socket in a temporary directory with fakes for the device,
# the commands and the authorizer.
describe TunnelgeistClient do
  {% if flag?(:darwin) %}
    alias Client = Tunnelgeist::Client
    alias Protocol = Tunnelgeist::Protocol

    UTUN9 = Tunnelgeist::InterfaceName.new("utun9")

    # The temporary directory of the test that runs, for its sockets.
    @directory = ""

    before do
      @directory = TunnelgeistTemporaryDirectory.create_temporary_directory
    end

    after do
      FileUtils.rm_rf(@directory)
    end

    # The path of the socket *name* in the test's temporary directory.
    def temporary_socket(name : String) : String
      TunnelgeistTemporaryDirectory.socket_path(@directory, name: name)
    end

    # A daemon on a short socket path: one fiber per accepted connection runs
    # `Handler#handle`. The fake device is one end of a datagram socketpair,
    # whose name the fake name lookup knows by its inode.
    class Daemon
      getter path : String
      # The temporary directory that holds the socket.
      @directory : String
      @server : UNIXServer
      getter commands = [] of Array(String)
      # The kernel's end of each fake device.
      getter peers = [] of IO::FileDescriptor
      getter registry = Tunnelgeist::Registry.new
      # The names the fake name lookup gave the descriptors it was asked
      # about, one per change request that carried one.
      getter verified = [] of Tunnelgeist::InterfaceName
      # The name of each fake device, by the inode of the client's end.
      @device_names = {} of UInt64 => Tunnelgeist::InterfaceName

      def initialize
        directory = TunnelgeistTemporaryDirectory.create_temporary_directory
        begin
          path = TunnelgeistTemporaryDirectory.socket_path(directory, name: "daemon")
          server = UNIXServer.new(path)
        rescue error
          FileUtils.rm_rf(directory)
          raise error
        end
        @directory = directory
        @path = path
        @server = server
        spawn accept_loop
      end

      def close : Nil
        @server.close
        FileUtils.rm_rf(@directory)
        @peers.each(&.close)
      end

      private def accept_loop : Nil
        loop do
          socket = @server.accept?
          break unless socket

          spawn handler.handle(socket)
        end
      end

      private def handler : Tunnelgeist::Handler
        Tunnelgeist::Handler.new(@registry,
          create_device: ->(name : Tunnelgeist::InterfaceName?, _mtu : Int32) { create_device(name) },
          run: ->(argv : Array(String)) { @commands << argv; Tunnelgeist::CommandRunner::Result.new(exit_status: 0, output: "", error: "") },
          admit: ->(_peer : Tunnelgeist::Peer) { TunnelgeistClientConfigs.open_admission },
          group: "tunnelgeist",
          interface_index: ->(_name : Tunnelgeist::InterfaceName) { 21_u32 },
          descriptor_name: ->(fd : Int32) { descriptor_name(fd) },
          log: Log.new("test", Log::MemoryBackend.new, :debug))
      end

      private def descriptor_name(fd : Int32) : Tunnelgeist::InterfaceName
        name = @device_names[inode(fd)]? || raise IO::Error.new("UTUN_OPT_IFNAME: Invalid argument")
        @verified << name
        name
      end

      # The inode of *fd*, which every copy of a descriptor shares.
      private def inode(fd : Int32) : UInt64
        raise IO::Error.from_errno("fstat") unless LibC.fstat(fd, out stat) == 0
        stat.st_ino.to_u64
      end

      private def create_device(name : Tunnelgeist::InterfaceName?) : Tunnelgeist::Device::Utun
        fds = StaticArray(Int32, 2).new(-1)
        raise IO::Error.from_errno("socketpair") if LibC.socketpair(LibC::AF_UNIX, LibC::SOCK_DGRAM, 0, fds) < 0

        peer = IO::FileDescriptor.new(fds[1])
        peer.sync = true
        peer.read_buffering = false
        @peers << peer
        device_name = name || UTUN9
        @device_names[inode(fds[0])] = device_name
        Tunnelgeist::Device::Utun.new(fd: fds[0], name: device_name)
      end
    end

    def with_daemon(&)
      daemon = Daemon.new
      begin
        yield daemon
      ensure
        daemon.close
      end
    end

    test "create returns a device whose descriptor is open, close-on-exec and carries a datagram" do
      with_daemon do |daemon|
        device = Client.new(daemon.path).create(mtu: 1_280)
        begin
          assert(device.name == UTUN9)
          assert(device.key.to_s.size == 43)
          assert(device.mtu == 1_280)
          flags = LibC.fcntl(device.fd, LibC::F_GETFD)
          assert(flags != -1)
          assert((flags & LibC::FD_CLOEXEC) != 0)
          status = LibC.fcntl(device.fd, LibC::F_GETFL)
          assert(status != -1)
          assert((status & LibC::O_NONBLOCK) == 0)

          frame = Bytes[0, 0, 0, 2, 0x45, 1, 2, 3]
          daemon.peers.first.write(frame)
          buffer = Bytes.new(64)
          count = LibC.read(device.fd, buffer, buffer.size)
          assert(count == frame.size)
          assert(buffer[0, count] == frame)
        ensure
          LibC.close(device.fd)
        end
      end
    end

    test "every change of a device carries its descriptor, which the daemon checks" do
      with_daemon do |daemon|
        device = Client.new(daemon.path).create
        begin
          prefix = Tunnelgeist::Prefix.parse("10.88.0.0/16")
          address = Tunnelgeist::Address.new(Socket::IPAddress.new("fd77::2", 0), prefix: 64)
          device.add_route(prefix)
          device.remove_route(prefix)
          device.add_address(address)
          device.remove_address(address)

          assert(daemon.verified == [UTUN9] * 4)
          assert(daemon.commands.includes?(Tunnelgeist::Commands.add_route(prefix, name: UTUN9)))
          assert(daemon.commands.includes?(Tunnelgeist::Commands.add_address(address, name: UTUN9)))
          assert(daemon.commands.includes?(Tunnelgeist::Commands.remove_address(address, name: UTUN9)))
          flags = LibC.fcntl(device.fd, LibC::F_GETFD)
          assert(flags != -1)
        ensure
          LibC.close(device.fd)
        end
      end
    end

    test "a handle cannot change its device and asks the daemon nothing" do
      with_daemon do |daemon|
        device = Client.new(daemon.path).create
        begin
          handles = [device.to_handle, Client.new(daemon.path).handle(device.name, key: device.key)]
          prefix = Tunnelgeist::Prefix.parse("10.89.0.0/16")
          address = Tunnelgeist::Address.new(Socket::IPAddress.new("fd77::2", 0), prefix: 64)
          before = daemon.commands.size

          handles.each do |handle|
            assert(!handle.is_a?(Client::Device))
            errors = [
              raised(Client::Error) { handle.add_route(prefix) },
              raised(Client::Error) { handle.remove_route(prefix) },
              raised(Client::Error) { handle.add_address(address) },
              raised(Client::Error) { handle.remove_address(address) },
            ]
            errors.each do |error|
              assert(error.reason.no_descriptor?)
              assert(error.message == "a handle cannot change utun9: a change needs the device's descriptor")
            end
          end
          assert(daemon.commands.size == before)
          assert(daemon.verified.empty?)
        ensure
          LibC.close(device.fd)
        end
      end
    end

    test "inspect and to_s of a device and a handle do not show the key" do
      with_daemon do |daemon|
        device = Client.new(daemon.path).create
        begin
          [device, device.to_handle].each do |item|
            [item.inspect, item.to_s, [item].inspect].each do |text|
              assert(!text.includes?(device.key.to_s))
              assert(text.includes?("key=[REDACTED]"))
              assert(text.includes?(%(name="utun9")))
            end
          end
        ensure
          LibC.close(device.fd)
        end
      end
    end

    test "a device the daemon no longer knows raises Client::Error with the unknown device text" do
      with_daemon do |daemon|
        device = Client.new(daemon.path).create
        begin
          daemon.registry.remove(device.name)
          error = raised(Client::Error) { device.add_route(Tunnelgeist::Prefix.parse("10.88.0.0/16")) }
          assert(error.message == Protocol::UNKNOWN_DEVICE)
          assert(error.reason.refused?)
        ensure
          LibC.close(device.fd)
        end
      end
    end

    test "a missing socket path raises Client::Error saying the daemon is not running" do
      path = temporary_socket("missing")
      error = raised(Client::Error) { Client.new(path).create }
      assert(error.message == "tunnelgeist is not running or not installed (#{path})")
      assert(error.reason.daemon_unavailable?)
    end

    test "a socket nothing listens on raises Client::Error saying the daemon is not running" do
      path = temporary_socket("unbound")
      socket = Socket.unix
      begin
        socket.bind(Socket::UNIXAddress.new(path))
        error = raised(Client::Error) { Client.new(path).create }
        assert(error.message == "tunnelgeist is not running or not installed (#{path})")
        assert(error.reason.daemon_unavailable?)
      ensure
        socket.close
      end
    end

    test "a daemon that closes the connection at once raises Client::Error, also for a broken pipe" do
      path = temporary_socket("close")
      server = UNIXServer.new(path)
      spawn do
        loop do
          socket = server.accept?
          break unless socket

          socket.close
        end
      end
      # A request larger than the socket buffers blocks in the write until
      # the daemon closes, so the write fails with EPIPE.
      routes = (0...4_000).map { |i| Tunnelgeist::Prefix.parse("10.#{i // 256}.#{i % 256}.0/24") }
      begin
        short = raised(Client::Error) { Client.new(path).create }
        assert(short.message == "tunnelgeist closed the connection without a complete reply")
        assert(short.reason.invalid_reply?)

        broken = raised(Client::Error) { Client.new(path).create(routes: routes) }
        assert(broken.message.to_s.starts_with?("tunnelgeist connection failed: "))
        assert(broken.message.to_s.includes?("Broken pipe"))
        assert(broken.cause.is_a?(IO::Error))
        assert(broken.reason.connection_failed?)
      ensure
        server.close
      end
    end

    test "a daemon that never answers raises Client::Error after the timeout" do
      path = temporary_socket("mute")
      server = UNIXServer.new(path)
      accepted = [] of UNIXSocket
      spawn do
        loop do
          socket = server.accept?
          break unless socket

          accepted << socket
        end
      end
      begin
        client = Client.new(path)
        client.timeout = 200.milliseconds
        error = raised(Client::Error) { client.create }
        assert(error.message.to_s.starts_with?("tunnelgeist did not answer within"))
        assert(error.reason.timeout?)
      ensure
        server.close
        accepted.each(&.close)
      end
    end

    test "a request that eats part of the deadline leaves the reply only the rest of it" do
      path = temporary_socket("slow")
      server = UNIXServer.new(path)
      limit = 400.milliseconds
      release = Channel(Nil).new
      finished = Channel(Nil).new
      # A request larger than the socket buffers, so the write blocks until
      # the stub reads it.
      routes = (0...4_000).map { |i| Tunnelgeist::Prefix.parse("10.#{i // 256}.#{i % 256}.0/24") }
      spawn do
        begin
          socket = server.accept?
          if socket
            begin
              # Half the deadline passes in the client's write.
              sleep(limit / 2)
              socket.gets
              # The reply comes after the client's deadline; the spec ends
              # the wait early once the client has failed.
              select
              when release.receive?
              when timeout(limit * 4)
              end
              socket.puts(%({"ok":true}))
            rescue IO::Error
              # The client has gone by now.
            ensure
              socket.close
            end
          end
        ensure
          finished.send(nil)
        end
      end
      begin
        client = Client.new(path)
        client.timeout = limit
        started = Time.instant
        error = raised(Client::Error) { client.create(routes: routes) }
        elapsed = started.elapsed

        assert(error.reason.timeout?)
        # One deadline for the write and the wait for the reply. Restarting
        # it per step takes about 1.5x; the margin absorbs scheduling jitter.
        assert(elapsed < limit * 1.2)
      ensure
        release.close
        server.close
        finished.receive
      end
    end

    test "an ok create reply without a descriptor raises Client::Error" do
      path = temporary_socket("nofd")
      server = UNIXServer.new(path)
      spawn do
        loop do
          socket = server.accept?
          break unless socket

          socket.gets
          socket.puts(%({"ok":true,"name":"utun9","key":"#{"k" * 43}"}))
          socket.close
        end
      end
      begin
        error = raised(Client::Error) { Client.new(path).create }
        assert(error.message == "tunnelgeist returned no device")
        assert(error.reason.no_device?)
      ensure
        server.close
      end
    end

    test "a socket path too long for a Unix socket raises Client::Error" do
      long_path = "/#{"a" * 200}"
      error = raised(Client::Error) { Client.new(long_path).create }
      assert(error.message.to_s.starts_with?("tunnelgeist connection failed: "))
      assert(error.cause.is_a?(ArgumentError))
      assert(error.reason.connection_failed?)
    end

    test "a descriptor that arrives with an error reply is closed" do
      path = temporary_socket("errfd")
      server = UNIXServer.new(path)
      pipe = StaticArray(Int32, 2).new(-1)
      assert(LibC.pipe(pipe) == 0)
      # The reader reports EOF once every copy of the write end is closed.
      LibC.fcntl(pipe[0], LibC::F_SETFL, LibC::O_NONBLOCK)
      spawn do
        socket = server.accept?
        if socket
          socket.gets
          Tunnelgeist::FdPassing.send(socket, data: %({"ok":false,"error":"nope"}\n).to_slice, fd: pipe[1])
          LibC.close(pipe[1])
          socket.close
        end
      end
      begin
        error = raised(Client::Error) { Client.new(path).create }
        assert(error.message == "nope")
        assert(error.reason.refused?)
        byte = Bytes.new(1)
        assert(LibC.read(pipe[0], byte, 1) == 0)
      ensure
        LibC.close(pipe[0])
        server.close
      end
    end
  {% end %}
end
