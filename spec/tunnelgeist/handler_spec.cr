require "../spec_helper"
require "../../src/tunnelgeist/handler"
require "./support/client_configs"
require "./support/descriptor_sender"
require "./support/prompt_calls"
require "./support/registrations"

# The request handler of the root helper (UA5, UP1 to UP7), with every
# collaborator replaced: the device creator, the command runner, the
# authorizer's admission, the interface index lookup and the lookup of the
# interface name of a received descriptor.
describe TunnelgeistHandler do
  {% if flag?(:darwin) %}
    alias Protocol = Tunnelgeist::Protocol
    alias Commands = Tunnelgeist::Commands
    alias FdPassing = Tunnelgeist::FdPassing
    alias Admission = Tunnelgeist::Authorizer::Admission
    alias Config = Tunnelgeist::Config
    alias Reason = Tunnelgeist::Refusal::Reason

    include TunnelgeistClientConfigs
    include TunnelgeistDescriptorSender
    include TunnelgeistPromptCalls

    REFUSAL = "not permitted: not in group tunnelgeist or not allowed by a client configuration"
    UTUN9   = Tunnelgeist::InterfaceName.new("utun9")
    UTUN8   = Tunnelgeist::InterfaceName.new("utun8")
    # `recv` flag: return at once when nothing is queued (sys/socket.h).
    MSG_DONTWAIT = 0x80

    # One call of the fake device creator.
    record CreateCall, name : Tunnelgeist::InterfaceName?, mtu : Int32

    # One call of the drain of the departure watcher: whether the registry
    # was empty and how many commands had run.
    record DrainCall, registry_empty : Bool, commands_run : Int32

    # A reply line and the descriptor that came with it, if any.
    record ReplyExchange, reply : Protocol::Reply, fd : Int32?

    # A stand-in for a utun device a client holds: the client's end of a
    # stream socket pair, which the fake name lookup knows by its inode. The
    # other end reads end of file once every copy of the client's end is
    # closed, the copies the handler received included.
    class FakeDevice
      getter client : UNIXSocket
      getter kernel : UNIXSocket

      def initialize(*, @client : UNIXSocket, @kernel : UNIXSocket)
      end

      # The client's descriptor, to send with a request.
      def fd : Int32
        @client.fd
      end

      # Whether no copy of the client's end is open any more.
      def closed_everywhere? : Bool
        byte = Bytes.new(1)
        LibC.recv(@kernel.fd, byte, 1, MSG_DONTWAIT) == 0
      end

      def close : Nil
        @client.close
        @kernel.close
      end
    end

    # A handler on fakes that record what it asked of them.
    class HandlerFixture
      getter registry : Tunnelgeist::Registry
      getter commands = [] of Array(String)
      getter backend = Log::MemoryBackend.new
      # The descriptors the fake device creator handed out.
      getter device_fds = [] of Int32
      getter create_calls = [] of CreateCall
      getter drain_calls = [] of DrainCall
      # The peers the fake authorizer was asked about.
      getter peers = [] of Tunnelgeist::Peer
      # The descriptors the fake name lookup was asked about.
      getter verified = [] of Int32
      # What the fake name lookup raises for every descriptor, when set.
      property lookup_error : IO::Error? = nil
      # Runs inside the fake command runner with the command, before its
      # result.
      property on_run : Proc(Array(String), Nil)? = nil
      # The interface names of the fake devices, by the inode of the client's
      # end.
      @device_names = {} of UInt64 => Tunnelgeist::InterfaceName
      # The program whose runs fail, with exit status 1.
      property failing : String? = nil
      # The program whose runs time out, nil when none does.
      property timing_out : String? = nil
      # What the fake authorizer answers for every peer; by default one
      # configuration that allows every address and route.
      property admission : Admission = TunnelgeistClientConfigs.open_admission
      property create_error : Exception? = nil
      # Runs inside the fake device creator, after the device exists.
      property on_create : Proc(Nil)? = nil
      getter indexes = {UTUN9 => 21_u32}
      # The standard output of `route -n get`; nil makes it fail as for a
      # destination the kernel has no route to.
      property route_get : String? = "   route to: 10.99.0.0\ndestination: 10.99.0.0\n       mask: 255.255.0.0\n  interface: utun9\n"

      # A fixture whose handler uses *registry*, by default one with the
      # default limits.
      def initialize(@registry : Tunnelgeist::Registry = Tunnelgeist::Registry.new)
      end

      def handler(request_timeout : Time::Span = Protocol::REQUEST_TIMEOUT,
                  max_connections_per_user : Int32 = Tunnelgeist::Handler::MAX_CONNECTIONS_PER_USER) : Tunnelgeist::Handler
        Tunnelgeist::Handler.new(registry,
          create_device: ->(name : Tunnelgeist::InterfaceName?, mtu : Int32) { create_device(name, mtu: mtu) },
          run: ->(argv : Array(String)) { run(argv) },
          admit: ->(peer : Tunnelgeist::Peer) { admit(peer) },
          group: "tunnelgeist",
          interface_index: ->(name : Tunnelgeist::InterfaceName) { @indexes[name]? || 0_u32 },
          request_timeout: request_timeout,
          drain_departures: -> { record_drain },
          descriptor_name: ->(fd : Int32) { descriptor_name(fd) },
          max_connections_per_user: max_connections_per_user,
          log: Log.new("tunnelgeist", backend, :debug))
      end

      # A fake device the name lookup takes for utun *name*; with nil, one it
      # takes for no utun device at all. The caller closes it.
      def fake_device(name : Tunnelgeist::InterfaceName?) : FakeDevice
        kernel, client = UNIXSocket.pair
        @device_names[inode(client.fd)] = name if name
        FakeDevice.new(client: client, kernel: kernel)
      end

      # The fake name lookup: records *fd* and answers the name of the fake
      # device it is a copy of; raises as `Device.name_of` does for any
      # other descriptor, and *lookup_error* when one is set.
      def descriptor_name(fd : Int32) : Tunnelgeist::InterfaceName
        @verified << fd
        error = @lookup_error
        raise error if error

        @device_names[inode(fd)]? || raise IO::Error.new("descriptor is not a kernel control socket")
      end

      # The inode of *fd*, which every copy of a descriptor shares.
      private def inode(fd : Int32) : UInt64
        raise IO::Error.from_errno("fstat") unless LibC.fstat(fd, out stat) == 0
        stat.st_ino.to_u64
      end

      # The fake authorizer: records *peer* and answers `admission`.
      def admit(peer : Tunnelgeist::Peer) : Admission
        @peers << peer
        @admission
      end

      # The fake drain of the departure watcher: records the state it ran in.
      def record_drain : Nil
        @drain_calls << DrainCall.new(registry_empty: registry.empty?, commands_run: commands.size)
      end

      # The write end of a fresh pipe stands in for the utun descriptor; the
      # read end is closed at once.
      def create_device(name : Tunnelgeist::InterfaceName?, *, mtu : Int32) : Tunnelgeist::Device::Utun
        @create_calls << CreateCall.new(name: name, mtu: mtu)
        error = @create_error
        raise error if error

        fds = StaticArray(Int32, 2).new(0)
        raise IO::Error.from_errno("pipe") unless LibC.pipe(fds) == 0
        LibC.close(fds[0])
        @device_fds << fds[1]
        @on_create.try &.call
        Tunnelgeist::Device::Utun.new(fd: fds[1], name: name || UTUN9)
      end

      def run(argv : Array(String)) : Tunnelgeist::CommandRunner::Result
        @commands << argv
        @on_run.try &.call(argv)
        if argv[0] == Commands::ROUTE && argv[2] == "get"
          output = @route_get
          reply = output ? result(0, output: output, error: "") : result(1, output: "", error: "route: writing to routing socket: not in table\n")
          return reply
        end
        if argv[0] == @timing_out
          timed_out = Tunnelgeist::CommandRunner::Result.new(exit_status: -1, output: "", error: "", timed_out_after: 10.seconds)
          return timed_out
        end
        argv[0] == @failing ? result(1, output: "", error: "#{File.basename(argv[0])}: File exists\n") : result(0, output: "", error: "")
      end

      private def result(exit_status : Int32, *, output : String, error : String) : Tunnelgeist::CommandRunner::Result
        Tunnelgeist::CommandRunner::Result.new(exit_status: exit_status, output: output, error: error)
      end

      # Every text the log captured.
      def log_text : String
        backend.entries.join("\n") do |entry|
          "#{entry.message} #{entry.data} #{entry.context} #{entry.exception.try(&.message)}"
        end
      end

      def logged?(text : String) : Bool
        log_text.includes?(text)
      end
    end

    def v4(last : Int32 = 2) : Tunnelgeist::Address
      Tunnelgeist::Address.new(
        Socket::IPAddress.new("10.77.0.#{last}", 0), prefix: 24, peer: Socket::IPAddress.new("10.77.0.1", 0))
    end

    def route(text : String) : Tunnelgeist::Prefix
      Tunnelgeist::Prefix.parse(text)
    end

    def closed?(fd : Int32) : Bool
      LibC.fcntl(fd, LibC::F_GETFD) == -1
    end

    def line(request : Protocol::Request) : String
      "#{request.to_json}\n"
    end

    # Reads one reply line and the descriptor that came with it.
    def read_reply(client : UNIXSocket) : ReplyExchange
      text = IO::Memory.new
      descriptor = nil
      buffer = Bytes.new(4_096)
      loop do
        received = FdPassing.receive(client, buffer: buffer)
        descriptor ||= received.fd
        text.write(buffer[0, received.size])
        break if received.size == 0 || text.to_s.ends_with?("\n")
      end
      ReplyExchange.new(reply: Protocol::Reply.parse(text.to_s.chomp), fd: descriptor)
    end

    # Sends *request* (when given) with the descriptors *fds* in one
    # message, runs the handler on the other end and returns the reply and
    # the descriptor that came with it. The handler's socket must be closed
    # afterwards.
    def exchange(fixture : HandlerFixture, *, request : String?, fds : Array(Int32) = [] of Int32, handler = fixture.handler,
                 & : UNIXSocket ->) : ReplyExchange
      client, server = UNIXSocket.pair
      begin
        send_many(client, data: request.to_slice, fds: fds) if request
        yield client
        handler.handle(server)
        assert(server.closed?)
        read_reply(client)
      ensure
        client.close
      end
    end

    def exchange(fixture : HandlerFixture, *, request : String?, fds : Array(Int32) = [] of Int32, handler = fixture.handler) : ReplyExchange
      exchange(fixture, request: request, fds: fds, handler: handler) { }
    end

    # Sends *request* with the descriptor of a fake device named *device*,
    # by default the request's own name, closes the spec's copy, runs the
    # handler and returns the reply. Checks that the handler left no copy of
    # the descriptor open.
    def change(fixture : HandlerFixture, request : Protocol::DeviceRequest, *, device : Tunnelgeist::InterfaceName? = request.name,
               handler = fixture.handler) : Protocol::Reply
      fake = fixture.fake_device(device)
      begin
        exchanged = exchange(fixture, request: line(request), fds: [fake.fd], handler: handler) { fake.client.close }
        assert(fake.closed_everywhere?)
        exchanged.reply
      ensure
        fake.close
      end
    end

    # Whether the entry of *name* has recorded *item*: it may be removed and
    # may not be added again. `Entry` keeps its arrays to itself, so its
    # checks are what shows them. Raises when the registry does not know
    # *name*, so a missing entry cannot pass for an item that is not
    # recorded.
    def recorded?(fixture : HandlerFixture, *, item : Tunnelgeist::Address | Tunnelgeist::Prefix,
                  name : Tunnelgeist::InterfaceName = UTUN9) : Bool
      result = fixture.registry.with_entry(name) do |entry|
        case item
        in Tunnelgeist::Address
          entry.check_remove_address(item).nil? && !entry.check_add_address(item).nil?
        in Tunnelgeist::Prefix
          entry.check_remove_route(item).nil? && !entry.check_add_route(item).nil?
        end
      end
      raise "the registry does not know #{name}" if result.is_a?(Tunnelgeist::Registry::Rejection)

      result
    end

    def register(fixture : HandlerFixture) : Nil
      TunnelgeistRegistrations.register(fixture.registry, UTUN9, index: 21_u32, addresses: [v4(2)], routes: [route("10.99.0.0/16")]) { }
    end

    test "create builds the device, configures it in order, registers it and passes the descriptor" do
      fixture = HandlerFixture.new
      request = Protocol::Create.new(name: nil, mtu: 1_400, addresses: [v4(2)], routes: [route("10.99.0.0/16"), route("fd99::/48")])

      client, server = UNIXSocket.pair
      client.write(line(request).to_slice)
      fixture.handler.handle(server)
      assert(server.closed?)
      assert(fixture.device_fds.size == 1)
      assert(closed?(fixture.device_fds[0]))
      exchanged = read_reply(client)
      client.close
      reply = exchanged.reply
      fd = exchanged.fd

      begin
        assert(reply.ok)
        assert(reply.name == UTUN9)
        assert(fd)
        assert(fixture.create_calls == [CreateCall.new(name: nil, mtu: 1_400)])
        assert(fixture.commands == [
          Commands.up(UTUN9),
          Commands.add_address(v4(2), name: UTUN9),
          Commands.add_route(route("10.99.0.0/16"), name: UTUN9),
          Commands.add_route(route("fd99::/48"), name: UTUN9),
        ])
        assert(fixture.registry.with_entry(UTUN9, &.index) == 21_u32)
        assert(recorded?(fixture, item: route("10.99.0.0/16")))
        assert(recorded?(fixture, item: route("fd99::/48")))
        assert(fixture.logged?("op=create name=utun9"))
      ensure
        fd.try { |descriptor| LibC.close(descriptor) }
      end
    end

    test "create drains the departure watcher once, after the commands ran and before the entry exists" do
      fixture = HandlerFixture.new
      request = Protocol::Create.new(name: nil, mtu: 1_400, addresses: [v4(2)], routes: [route("10.99.0.0/16")])

      exchanged = exchange(fixture, request: line(request))
      exchanged.fd.try { |descriptor| LibC.close(descriptor) }

      assert(exchanged.reply.ok)
      assert(fixture.commands.size == 3)
      assert(fixture.drain_calls == [DrainCall.new(registry_empty: true, commands_run: 3)])
      assert(!fixture.registry.empty?)
    end

    test "a create whose commands fail does not drain the departure watcher" do
      fixture = HandlerFixture.new
      fixture.failing = "/sbin/route"

      reply = exchange(fixture, request: line(Protocol::Create.new(name: nil, mtu: 1_280, addresses: [] of Tunnelgeist::Address, routes: [route("10.99.0.0/16")]))).reply

      assert(!reply.ok)
      assert(fixture.drain_calls.empty?)
    end

    test "create with a failing route command replies the error, closes the descriptor and registers nothing" do
      fixture = HandlerFixture.new
      fixture.failing = "/sbin/route"
      request = Protocol::Create.new(name: UTUN9, mtu: 1_280, addresses: [v4(2)], routes: [route("10.99.0.0/16"), route("10.98.0.0/16")])

      exchanged = exchange(fixture, request: line(request))
      reply = exchanged.reply
      fd = exchanged.fd

      assert(!reply.ok)
      assert(reply.error == "/sbin/route exited 1: route: File exists")
      assert(fd.nil?)
      assert(closed?(fixture.device_fds[0]))
      assert(fixture.registry.empty?)
      assert(fixture.commands == [
        Commands.up(UTUN9),
        Commands.add_address(v4(2), name: UTUN9),
        Commands.add_route(route("10.99.0.0/16"), name: UTUN9),
      ])
    end

    test "create with an ifconfig that runs out of time replies the timeout and registers nothing" do
      fixture = HandlerFixture.new
      fixture.timing_out = "/sbin/ifconfig"

      reply = exchange(fixture, request: line(Protocol::Create.new(name: UTUN9, mtu: 1_280, addresses: [v4(2)], routes: [] of Tunnelgeist::Prefix))).reply

      assert(!reply.ok)
      assert(reply.error == "ifconfig timed out after 10 s")
      assert(fixture.registry.empty?)
    end

    test "a failed create of a unit the kernel chose logs the interface name" do
      fixture = HandlerFixture.new
      fixture.failing = "/sbin/ifconfig"

      reply = exchange(fixture, request: line(Protocol::Create.new(name: nil, mtu: 1_280, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix))).reply

      assert(!reply.ok)
      assert(fixture.logged?("op=create name=utun9 failed"))
    end

    test "create replies an error when the new interface has no index" do
      fixture = HandlerFixture.new
      fixture.indexes.clear

      exchanged = exchange(fixture, request: line(Protocol::Create.new(name: nil, mtu: 1_280, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix)))
      reply = exchanged.reply
      fd = exchanged.fd

      assert(!reply.ok)
      assert(reply.error.to_s.includes?("utun9"))
      assert(fd.nil?)
      assert(closed?(fixture.device_fds[0]))
      assert(fixture.registry.empty?)
    end

    test "create replies the error of the device creator, such as a busy unit, and registers nothing" do
      fixture = HandlerFixture.new
      fixture.create_error = IO::Error.from_os_error("Cannot connect to utun9", Errno::EBUSY)

      exchanged = exchange(fixture, request: line(Protocol::Create.new(name: UTUN9, mtu: 1_280, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix)))
      reply = exchanged.reply
      fd = exchanged.fd

      assert(!reply.ok)
      assert(reply.error.to_s.downcase.includes?("busy"))
      assert(fd.nil?)
      assert(fixture.registry.empty?)
      assert(fixture.commands.empty?)
    end

    test "a create the kernel gives a registered unit replaces the stale entry and logs the replacement" do
      fixture = HandlerFixture.new
      register(fixture)
      fixture.indexes[UTUN9] = 23_u32

      exchanged = exchange(fixture, request: line(Protocol::Create.new(name: nil, mtu: 1_280, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix)))
      reply = exchanged.reply
      fd = exchanged.fd
      fd.try { |descriptor| LibC.close(descriptor) }

      assert(reply.ok)
      assert(fixture.registry.with_entry(UTUN9, &.index) == 23_u32)
      assert(!recorded?(fixture, item: route("10.99.0.0/16")))
      warning = fixture.backend.entries.find { |entry| entry.severity.warn? && entry.message.includes?("replaced") }
      assert(warning)
      assert(warning.try(&.message.ends_with?("op=create name=utun9 replaced stale entry: interface index 21 now 23")))
    end

    test "a client that closes before reading the create reply leaves nothing registered" do
      fixture = HandlerFixture.new
      client, server = UNIXSocket.pair
      client.write(line(Protocol::Create.new(name: nil, mtu: 1_280, addresses: [v4(2)], routes: [] of Tunnelgeist::Prefix)).to_slice)
      fixture.on_create = -> { client.close }

      fixture.handler.handle(server)

      assert(server.closed?)
      assert(fixture.registry.empty?)
      assert(closed?(fixture.device_fds[0]))
      assert(fixture.commands.size == 2)
    end

    test "add_route and remove_route run the command and update the entry" do
      fixture = HandlerFixture.new
      register(fixture)

      added = change(fixture, Protocol::AddRoute.new(name: UTUN9, route: route("10.98.0.0/16")))
      removed = change(fixture, Protocol::RemoveRoute.new(name: UTUN9, route: route("10.99.0.0/16")))

      assert(added == Protocol::Reply.new(ok: true))
      assert(removed == Protocol::Reply.new(ok: true))
      assert(fixture.commands == [
        Commands.add_route(route("10.98.0.0/16"), name: UTUN9),
        Commands.get_route(route("10.99.0.0/16")),
        Commands.remove_route(route("10.99.0.0/16"), name: UTUN9),
      ])
      assert(recorded?(fixture, item: route("10.98.0.0/16")))
      assert(!recorded?(fixture, item: route("10.99.0.0/16")))
      assert(fixture.logged?("op=add_route name=utun9"))
    end

    test "remove_route deletes nothing when the route no longer points at the device and forgets it" do
      outputs = [
        "   route to: 10.99.0.0\ndestination: 10.99.0.0\n       mask: 255.255.0.0\n  interface: en0\n",
        "   route to: 10.99.0.0\ndestination: 10.99.0.0\n       mask: 255.255.0.0\n  interface: utun90\n",
        nil,
      ]
      outputs.each do |output|
        fixture = HandlerFixture.new
        fixture.route_get = output
        register(fixture)

        reply = change(fixture, Protocol::RemoveRoute.new(name: UTUN9, route: route("10.99.0.0/16")))

        assert(reply == Protocol::Reply.new(ok: true))
        assert(fixture.commands == [Commands.get_route(route("10.99.0.0/16"))])
        assert(!recorded?(fixture, item: route("10.99.0.0/16")))
        assert(fixture.logged?("route 10.99.0.0/16 no longer on utun9, forgotten"))
      end
    end

    test "remove_route of a route gone from a device that departs meanwhile does not log it as forgotten" do
      fixture = HandlerFixture.new
      fixture.route_get = "   route to: 10.99.0.0\ndestination: 10.99.0.0\n       mask: 255.255.0.0\n  interface: en0\n"
      register(fixture)
      fixture.on_run = ->(argv : Array(String)) do
        fixture.registry.remove(UTUN9) if argv == Commands.get_route(route("10.99.0.0/16"))
        nil
      end

      reply = change(fixture, Protocol::RemoveRoute.new(name: UTUN9, route: route("10.99.0.0/16")))

      assert(reply.error == Protocol::UNKNOWN_DEVICE)
      assert(fixture.logged?("op=remove_route name=utun9 failed: unknown device"))
      assert(!fixture.logged?("forgotten"))
    end

    test "remove_route of an IPv6 route asks route get with -inet6" do
      fixture = HandlerFixture.new
      TunnelgeistRegistrations.register(fixture.registry, UTUN9, index: 21_u32, addresses: [v4(2)], routes: [route("fd99::/48")]) { }

      reply = change(fixture, Protocol::RemoveRoute.new(name: UTUN9, route: route("fd99::/48")))

      assert(reply.ok)
      assert(fixture.commands == [
        ["/sbin/route", "-n", "get", "-inet6", "fd99::/48"],
        Commands.remove_route(route("fd99::/48"), name: UTUN9),
      ])
    end

    test "add_address and remove_address run the command and update the entry" do
      fixture = HandlerFixture.new
      register(fixture)

      added = change(fixture, Protocol::AddAddress.new(name: UTUN9, address: v4(3)))
      removed = change(fixture, Protocol::RemoveAddress.new(name: UTUN9, address: v4(2)))

      assert(added.ok)
      assert(removed.ok)
      assert(fixture.commands == [
        Commands.add_address(v4(3), name: UTUN9),
        Commands.remove_address(v4(2), name: UTUN9),
      ])
      assert(recorded?(fixture, item: v4(3)))
      assert(!recorded?(fixture, item: v4(2)))
    end

    test "a change of a device the daemon does not know gets UNKNOWN_DEVICE and runs nothing" do
      fixture = HandlerFixture.new
      register(fixture)

      unknown = change(fixture, Protocol::AddRoute.new(name: Tunnelgeist::InterfaceName.new("utun8"), route: route("10.98.0.0/16")))

      assert(unknown.error == Protocol::UNKNOWN_DEVICE)
      assert(fixture.logged?("op=add_route name=utun8 failed: unknown device"))
      assert(fixture.commands.empty?)
      assert(recorded?(fixture, item: route("10.99.0.0/16")))
      assert(!recorded?(fixture, item: route("10.98.0.0/16")))
    end

    test "a change whose interface index changed or vanished gets UNKNOWN_DEVICE and removes the entry" do
      [22_u32, 0_u32].each do |index|
        fixture = HandlerFixture.new
        register(fixture)
        fixture.indexes[UTUN9] = index

        reply = change(fixture, Protocol::RemoveRoute.new(name: UTUN9, route: route("10.99.0.0/16")))

        assert(reply.error == Protocol::UNKNOWN_DEVICE)
        assert(fixture.registry.empty?)
        assert(fixture.commands.empty?)
      end
    end

    test "a change the entry refuses runs no command" do
      fixture = HandlerFixture.new
      register(fixture)

      duplicate = change(fixture, Protocol::AddRoute.new(name: UTUN9, route: route("10.99.0.0/16")))
      foreign = change(fixture, Protocol::RemoveAddress.new(name: UTUN9, address: v4(5)))

      assert(duplicate.error == "route 10.99.0.0/16 already on utun9")
      assert(foreign.error == "address 10.77.0.5 was not added by the helper")
      assert(fixture.logged?("op=add_route name=utun9 failed: route 10.99.0.0/16 already on utun9"))
      assert(fixture.logged?("op=remove_address name=utun9 failed: address 10.77.0.5 was not added by the helper"))
      assert(fixture.commands.empty?)
    end

    test "a failed change command replies the error and leaves the entry unchanged" do
      fixture = HandlerFixture.new
      fixture.failing = "/sbin/route"
      register(fixture)

      reply = change(fixture, Protocol::RemoveRoute.new(name: UTUN9, route: route("10.99.0.0/16")))

      assert(reply.error == "/sbin/route exited 1: route: File exists")
      assert(recorded?(fixture, item: route("10.99.0.0/16")))
      assert(!recorded?(fixture, item: route("10.98.0.0/16")))
    end

    test "a change without a descriptor is refused before anything is looked up or run" do
      fixture = HandlerFixture.new
      register(fixture)

      reply = exchange(fixture, request: line(Protocol::AddRoute.new(name: UTUN9, route: route("10.98.0.0/16")))).reply

      assert(reply == Protocol::Reply.new(ok: false, error: "request must carry the device's descriptor"))
      assert(fixture.verified.empty?)
      assert(fixture.commands.empty?)
      assert(!recorded?(fixture, item: route("10.98.0.0/16")))
      assert(fixture.logged?("op=add_route name=utun9 failed: request must carry the device's descriptor"))
    end

    test "a change with two descriptors is refused and both are closed" do
      fixture = HandlerFixture.new
      register(fixture)
      first = fixture.fake_device(UTUN9)
      second = fixture.fake_device(UTUN9)
      begin
        request = line(Protocol::RemoveRoute.new(name: UTUN9, route: route("10.99.0.0/16")))
        reply = exchange(fixture, request: request, fds: [first.fd, second.fd]) do
          first.client.close
          second.client.close
        end.reply

        assert(reply == Protocol::Reply.new(ok: false, error: "request must carry only the device's descriptor"))
        assert(first.closed_everywhere?)
        assert(second.closed_everywhere?)
        assert(fixture.verified.empty?)
        assert(fixture.commands.empty?)
        assert(recorded?(fixture, item: route("10.99.0.0/16")))
      ensure
        first.close
        second.close
      end
    end

    test "a change with a descriptor that is no utun device is refused and the descriptor closed" do
      fixture = HandlerFixture.new
      register(fixture)

      reply = change(fixture, Protocol::AddAddress.new(name: UTUN9, address: v4(3)), device: nil)

      assert(reply == Protocol::Reply.new(ok: false, error: "descriptor is not a utun device"))
      assert(fixture.verified.size == 1)
      assert(fixture.commands.empty?)
      assert(!recorded?(fixture, item: v4(3)))
      assert(fixture.logged?("op=add_address name=utun9 failed: descriptor is not a utun device"))
    end

    test "a failed lookup of the utun control is logged as the daemon's error and refuses the change" do
      fixture = HandlerFixture.new
      register(fixture)
      fixture.lookup_error = Tunnelgeist::Device::ControlLookupError.new("CTLIOCGINFO com.apple.net.utun_control: Operation not permitted")

      reply = change(fixture, Protocol::AddRoute.new(name: UTUN9, route: route("10.98.0.0/16")))

      assert(reply == Protocol::Reply.new(ok: false, error: "descriptor is not a utun device"))
      assert(fixture.commands.empty?)
      logged = fixture.backend.entries.find { |entry| entry.severity.error? }
      assert(logged)
      assert(logged.try(&.message.ends_with?(
        "op=add_route name=utun9 utun control lookup failed: CTLIOCGINFO com.apple.net.utun_control: Operation not permitted")))
    end

    test "a descriptor that is no utun device is not logged as the daemon's error" do
      fixture = HandlerFixture.new
      register(fixture)

      reply = change(fixture, Protocol::AddRoute.new(name: UTUN9, route: route("10.98.0.0/16")), device: nil)

      assert(reply.error == "descriptor is not a utun device")
      assert(fixture.backend.entries.none?(&.severity.error?))
    end

    test "a change with the descriptor of another device is refused, names both and runs nothing" do
      fixture = HandlerFixture.new
      register(fixture)
      TunnelgeistRegistrations.register(fixture.registry, UTUN8, index: 20_u32, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix) { }

      reply = change(fixture, Protocol::RemoveAddress.new(name: UTUN9, address: v4(2)), device: UTUN8)

      assert(reply == Protocol::Reply.new(ok: false, error: "descriptor is utun8, not utun9"))
      assert(fixture.commands.empty?)
      assert(recorded?(fixture, item: v4(2)))
      assert(fixture.logged?("op=remove_address name=utun9 failed: descriptor is utun8, not utun9"))
    end

    test "a change holds the descriptor while its command runs and closes it afterwards" do
      fixture = HandlerFixture.new
      register(fixture)
      device = fixture.fake_device(UTUN9)
      held = [] of Bool
      fixture.on_run = ->(_argv : Array(String)) { held << !device.closed_everywhere?; nil }
      begin
        request = line(Protocol::AddRoute.new(name: UTUN9, route: route("10.98.0.0/16")))
        reply = exchange(fixture, request: request, fds: [device.fd]) { device.client.close }.reply

        assert(reply.ok)
        assert(held == [true])
        assert(device.closed_everywhere?)
        assert(recorded?(fixture, item: route("10.98.0.0/16")))
      ensure
        device.close
      end
    end

    test "a change refused by the registry closes the descriptor too" do
      fixture = HandlerFixture.new
      register(fixture)

      reply = change(fixture, Protocol::AddRoute.new(name: Tunnelgeist::InterfaceName.new("utun8"), route: route("10.98.0.0/16")))

      assert(reply.error == Protocol::UNKNOWN_DEVICE)
      assert(fixture.verified.size == 1)
    end

    # Makes every command that names utun9 wait until *gate* gets a value;
    # *started* receives each such command as it starts waiting.
    def hold_utun9_commands(fixture : HandlerFixture, *, gate : Channel(Nil), started : Channel(Array(String))) : Nil
      fixture.on_run = ->(argv : Array(String)) do
        if argv.includes?(UTUN9.to_s)
          started.send(argv)
          gate.receive
        end
        nil
      end
    end

    # Registers utun9 and utun8 and starts adding the route 10.98.0.0/16 to
    # utun9, whose command waits until *gate* gets a value; returns once that
    # command runs, with the channel that receives the reply.
    def start_held_change(fixture : HandlerFixture, *, gate : Channel(Nil)) : Channel(Protocol::Reply | Exception)
      register(fixture)
      TunnelgeistRegistrations.register(fixture.registry, UTUN8, index: 22_u32, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix) { }
      fixture.indexes[UTUN8] = 22_u32
      started = Channel(Array(String)).new(4)
      hold_utun9_commands(fixture, gate: gate, started: started)
      held = later { change(fixture, Protocol::AddRoute.new(name: UTUN9, route: route("10.98.0.0/16"))) }
      assert(promptly { started.receive } == Commands.add_route(route("10.98.0.0/16"), name: UTUN9))
      held
    end

    test "a change waiting for its command does not hold up a change of another device" do
      fixture = HandlerFixture.new
      gate = Channel(Nil).new
      held = start_held_change(fixture, gate: gate)

      other = promptly { change(fixture, Protocol::AddRoute.new(name: UTUN8, route: route("10.97.0.0/16"))) }

      assert(other.ok)
      assert(recorded?(fixture, item: route("10.97.0.0/16"), name: UTUN8))
      gate.send(nil)
      assert(awaited(held).ok)
      assert(recorded?(fixture, item: route("10.98.0.0/16")))
    end

    test "a change waiting for its command does not hold up a create" do
      fixture = HandlerFixture.new
      gate = Channel(Nil).new
      held = start_held_change(fixture, gate: gate)
      utun7 = Tunnelgeist::InterfaceName.new("utun7")
      fixture.indexes[utun7] = 23_u32
      request = Protocol::Create.new(name: utun7, mtu: 1_280, addresses: [] of Tunnelgeist::Address, routes: [route("10.97.0.0/16")])

      created = promptly { exchange(fixture, request: line(request)) }
      created.fd.try { |fd| LibC.close(fd) }

      assert(created.reply.ok)
      assert(recorded?(fixture, item: route("10.97.0.0/16"), name: utun7))
      gate.send(nil)
      assert(awaited(held).ok)
    end

    test "a change waiting for its command does not hold up the departure of another device or the idle check" do
      fixture = HandlerFixture.new
      gate = Channel(Nil).new
      held = start_held_change(fixture, gate: gate)

      assert(promptly { fixture.registry.remove(UTUN8) })
      assert(!promptly { fixture.registry.empty? })

      gate.send(nil)
      assert(awaited(held).ok)
      assert(recorded?(fixture, item: route("10.98.0.0/16")))
    end

    test "the departure of a device whose change waits for its command returns at once and the change records nothing" do
      fixture = HandlerFixture.new
      gate = Channel(Nil).new
      held = start_held_change(fixture, gate: gate)

      assert(promptly { fixture.registry.remove(UTUN9) })
      gate.send(nil)
      reply = awaited(held)

      assert(reply.error == Protocol::UNKNOWN_DEVICE)
      assert(fixture.logged?("op=add_route name=utun9 failed: unknown device"))
      assert(fixture.registry.with_entry(UTUN9) { } == Tunnelgeist::Registry::Rejection.unknown_device)
    end

    test "a change whose entry a create replaced while its command ran records nothing in the new entry" do
      fixture = HandlerFixture.new
      gate = Channel(Nil).new
      held = start_held_change(fixture, gate: gate)

      promptly { TunnelgeistRegistrations.register(fixture.registry, UTUN9, index: 24_u32, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix) { } }
      gate.send(nil)
      reply = awaited(held)

      assert(reply.error == Protocol::UNKNOWN_DEVICE)
      assert(fixture.registry.with_entry(UTUN9, &.index) == 24_u32)
      assert(!recorded?(fixture, item: route("10.98.0.0/16")))
    end

    test "a change waiting for the entry of a device that departs runs no command and gets UNKNOWN_DEVICE" do
      fixture = HandlerFixture.new
      gate = Channel(Nil).new
      held = start_held_change(fixture, gate: gate)
      waiting = later { change(fixture, Protocol::AddRoute.new(name: UTUN9, route: route("10.97.0.0/16"))) }
      # The second change has pinned its descriptor once the name lookup saw
      # it, and then waits for the entry the first one holds.
      promptly do
        until fixture.verified.size == 2
          sleep 1.millisecond
        end
      end
      Fiber.yield

      assert(fixture.commands.size == 1)
      assert(promptly { fixture.registry.remove(UTUN9) })
      gate.send(nil)

      assert(awaited(held).error == Protocol::UNKNOWN_DEVICE)
      assert(awaited(waiting).error == Protocol::UNKNOWN_DEVICE)
      assert(fixture.commands.size == 1)
    end

    test "a descriptor sent with a create is closed and the create goes on" do
      fixture = HandlerFixture.new
      device = fixture.fake_device(UTUN9)
      begin
        request = line(Protocol::Create.new(name: nil, mtu: 1_280, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix))
        exchanged = exchange(fixture, request: request, fds: [device.fd]) { device.client.close }
        exchanged.fd.try { |descriptor| LibC.close(descriptor) }

        assert(exchanged.reply.ok)
        assert(device.closed_everywhere?)
        assert(fixture.verified.empty?)
      ensure
        device.close
      end
    end

    test "a descriptor sent with a malformed request is closed" do
      fixture = HandlerFixture.new
      device = fixture.fake_device(UTUN9)
      begin
        reply = exchange(fixture, request: "{\"version\": 1,\n", fds: [device.fd]) { device.client.close }.reply

        assert(!reply.ok)
        assert(device.closed_everywhere?)
        assert(fixture.verified.empty?)
      ensure
        device.close
      end
    end

    test "two descriptors in two messages of one line are refused and both are closed" do
      fixture = HandlerFixture.new
      register(fixture)
      first = fixture.fake_device(UTUN9)
      second = fixture.fake_device(UTUN9)
      begin
        text = line(Protocol::AddRoute.new(name: UTUN9, route: route("10.98.0.0/16")))
        reply = exchange(fixture, request: text[0, 10], fds: [first.fd]) do |client|
          send_many(client, data: text[10..].to_slice, fds: [second.fd])
          first.client.close
          second.client.close
        end.reply

        assert(reply == Protocol::Reply.new(ok: false, error: "request must carry only the device's descriptor"))
        assert(first.closed_everywhere?)
        assert(second.closed_everywhere?)
        assert(fixture.verified.empty?)
        assert(fixture.commands.empty?)
      ensure
        first.close
        second.close
      end
    end

    test "a line dripped in one-byte messages that each carry a descriptor is refused at the second" do
      fixture = HandlerFixture.new
      device = fixture.fake_device(UTUN9)
      client, server = UNIXSocket.pair
      sent = Channel(Int32).new(1)
      # The sender waits while the socket buffer is full, so the handler
      # reads the messages as they come; once it refuses and closes, the
      # next send fails.
      spawn do
        count = 0
        begin
          300.times do
            FdPassing.send(client, data: Bytes['{'.ord.to_u8], fd: device.fd)
            count += 1
          end
        rescue IO::Error
          # The handler has closed the connection; that is the case under test.
        ensure
          sent.send(count)
        end
      end
      begin
        fixture.handler.handle(server)
        reply = read_reply(client).reply
        count = sent.receive
        device.client.close

        assert(reply == Protocol::Reply.new(ok: false, error: "request must carry only the device's descriptor"))
        assert(count < 300)
        assert(device.closed_everywhere?)
        assert(fixture.verified.empty?)
      ensure
        client.close
        device.close
      end
    end

    test "a descriptor sent with an empty line is closed" do
      fixture = HandlerFixture.new
      device = fixture.fake_device(UTUN9)
      begin
        reply = exchange(fixture, request: "\n", fds: [device.fd]) { device.client.close }.reply

        assert(reply == Protocol::Reply.new(ok: false, error: "no request"))
        assert(device.closed_everywhere?)
      ensure
        device.close
      end
    end

    test "a descriptor sent with a line that does not end in time is closed" do
      fixture = HandlerFixture.new
      device = fixture.fake_device(UTUN9)
      begin
        reply = exchange(fixture, request: "{", fds: [device.fd], handler: fixture.handler(request_timeout: 100.milliseconds)) do
          device.client.close
        end.reply

        assert(reply.error.to_s.starts_with?("no request within"))
        assert(device.closed_everywhere?)
      ensure
        device.close
      end
    end

    test "a descriptor that comes with a later piece of the line is the request's" do
      fixture = HandlerFixture.new
      register(fixture)
      device = fixture.fake_device(UTUN9)
      begin
        text = line(Protocol::AddRoute.new(name: UTUN9, route: route("10.98.0.0/16")))
        reply = exchange(fixture, request: text[0, 10]) do |client|
          send_many(client, data: text[10..].to_slice, fds: [device.fd])
          device.client.close
        end.reply

        assert(reply.ok)
        assert(device.closed_everywhere?)
        assert(fixture.verified.size == 1)
      ensure
        device.close
      end
    end

    test "a peer outside the main group gets the refusal, nothing is created or run, and the log says check=group" do
      fixture = HandlerFixture.new
      fixture.admission = Admission.refused_group

      exchanged = exchange(fixture, request: line(Protocol::Create.new(name: nil, mtu: 1_280, addresses: [v4(2)], routes: [] of Tunnelgeist::Prefix)))
      reply = exchanged.reply
      fd = exchanged.fd

      assert(reply == Protocol::Reply.new(ok: false, error: REFUSAL))
      assert(fd.nil?)
      assert(fixture.create_calls.empty?)
      assert(fixture.commands.empty?)
      peer = fixture.peers.first
      assert(fixture.logged?("uid=#{peer.uid} pid=#{peer.pid} refused check=group"))
      assert(!fixture.logged?("check=config"))
      assert(!fixture.logged?("op="))
    end

    test "a peer no configuration applies to gets the refusal and the log names each configuration's reason" do
      fixture = HandlerFixture.new
      fixture.admission = Admission.new(clients: [] of Config::Client,
        refusals: [client_refusal("default", reason: Reason::Users), client_refusal("signed", reason: Reason::Requirement),
                   client_refusal("vpn", reason: Reason::HardenedRuntime),
                   Tunnelgeist::Authorizer::ClientRefusal.new(name: "dev",
                     refusal: Tunnelgeist::Refusal.entitlement(Tunnelgeist::Entitlement::AllowDyldEnvironmentVariables))])

      exchanged = exchange(fixture, request: line(Protocol::Create.new(name: nil, mtu: 1_280, addresses: [v4(2)], routes: [] of Tunnelgeist::Prefix)))

      assert(exchanged.reply == Protocol::Reply.new(ok: false, error: REFUSAL))
      assert(exchanged.fd.nil?)
      assert(fixture.create_calls.empty?)
      assert(fixture.commands.empty?)
      peer = fixture.peers.first
      assert(fixture.logged?(%(uid=#{peer.uid} pid=#{peer.pid} refused check=config ) +
                             %(default=users signed=requirement vpn="hardened runtime" ) +
                             %(dev="entitlement com.apple.security.cs.allow-dyld-environment-variables")))
      assert(!fixture.logged?("op="))
    end

    test "a refused peer holding the device's descriptor gets the same refusal and changes nothing" do
      fixture = HandlerFixture.new
      register(fixture)
      fixture.admission = Admission.new(clients: [] of Config::Client, refusals: [client_refusal("vpn", reason: Reason::Requirement)])

      reply = change(fixture, Protocol::RemoveRoute.new(name: UTUN9, route: route("10.99.0.0/16")))

      assert(reply.error == REFUSAL)
      assert(fixture.commands.empty?)
      assert(recorded?(fixture, item: route("10.99.0.0/16")))
      assert(!recorded?(fixture, item: route("10.98.0.0/16")))
      assert(fixture.logged?("refused check=config vpn=requirement"))
    end

    test "an admission that raises is a refusal" do
      fixture = HandlerFixture.new
      handler = Tunnelgeist::Handler.new(fixture.registry,
        create_device: ->(name : Tunnelgeist::InterfaceName?, mtu : Int32) { fixture.create_device(name, mtu: mtu) },
        run: ->(argv : Array(String)) { fixture.run(argv) },
        admit: ->(_peer : Tunnelgeist::Peer) : Admission { raise "directory unavailable" },
        group: "tunnelgeist",
        interface_index: ->(_name : Tunnelgeist::InterfaceName) { 21_u32 },
        log: Log.new("tunnelgeist", fixture.backend, :debug))

      reply = exchange(fixture, request: line(Protocol::Create.new(name: nil, mtu: 1_280, addresses: [v4(2)], routes: [] of Tunnelgeist::Prefix)), handler: handler).reply

      assert(reply.error == REFUSAL)
      assert(fixture.create_calls.empty?)
      assert(fixture.logged?("refused check=Exception: directory unavailable"))
    end

    test "an admission that raises an IO::Error is a refusal logged with the error class" do
      fixture = HandlerFixture.new
      handler = Tunnelgeist::Handler.new(fixture.registry,
        create_device: ->(name : Tunnelgeist::InterfaceName?, mtu : Int32) { fixture.create_device(name, mtu: mtu) },
        run: ->(argv : Array(String)) { fixture.run(argv) },
        admit: ->(_peer : Tunnelgeist::Peer) : Admission { raise IO::Error.new("mbr_check_membership: Resource busy") },
        group: "tunnelgeist",
        interface_index: ->(_name : Tunnelgeist::InterfaceName) { 21_u32 },
        log: Log.new("tunnelgeist", fixture.backend, :debug))

      reply = exchange(fixture, request: line(Protocol::Create.new(name: nil, mtu: 1_280, addresses: [v4(2)], routes: [] of Tunnelgeist::Prefix)), handler: handler).reply

      assert(reply.error == REFUSAL)
      assert(fixture.create_calls.empty?)
      assert(fixture.logged?("check=IO::Error: mbr_check_membership: Resource busy"))
    end

    test "create with an address no applying configuration allows runs nothing, replies the address and logs the configurations" do
      fixture = HandlerFixture.new
      fixture.admission = applying([
        client("lab", addresses: [rule("10.1.0.0/16", peer: "10.1.0.0/16")], routes: ["10.99.0.0/16"]),
        client("vpn", addresses: [rule("fd77::/16")], routes: ["fd99::/16"]),
      ])
      request = Protocol::Create.new(name: nil, mtu: 1_280, addresses: [v4(2)], routes: [route("10.99.0.0/16")])

      exchanged = exchange(fixture, request: line(request))

      assert(exchanged.reply == Protocol::Reply.new(ok: false, error: "address 10.77.0.2/24 not allowed"))
      assert(exchanged.fd.nil?)
      assert(fixture.create_calls.empty?)
      assert(fixture.commands.empty?)
      assert(fixture.drain_calls.empty?)
      assert(fixture.registry.empty?)
      assert(fixture.logged?("op=create name=- failed: address 10.77.0.2/24 not allowed configs=lab,vpn"))
    end

    test "create of a named device with a route no applying configuration allows runs nothing and logs the name" do
      fixture = HandlerFixture.new
      fixture.admission = applying([client("lab", addresses: [rule("10.77.0.0/16", peer: "10.77.0.0/24")], routes: ["10.0.0.0/8"])])
      request = Protocol::Create.new(name: UTUN9, mtu: 1_280, addresses: [v4(2)], routes: [route("10.99.0.0/16"), route("fd99::/48")])

      exchanged = exchange(fixture, request: line(request))

      assert(exchanged.reply == Protocol::Reply.new(ok: false, error: "route fd99::/48 not allowed"))
      assert(exchanged.fd.nil?)
      assert(fixture.create_calls.empty?)
      assert(fixture.commands.empty?)
      assert(fixture.registry.empty?)
      assert(fixture.logged?("op=create name=utun9 failed: route fd99::/48 not allowed configs=lab"))
    end

    test "create with items the applying configurations allow together configures the device as before" do
      fixture = HandlerFixture.new
      fixture.admission = applying([
        client("lab", addresses: [rule("10.77.0.0/16", peer: "10.77.0.0/24")], routes: [] of String),
        client("routes", addresses: [] of Config::AddressRule, routes: ["10.0.0.0/8"]),
      ])
      request = Protocol::Create.new(name: nil, mtu: 1_280, addresses: [v4(2)], routes: [route("10.99.0.0/16")])

      exchanged = exchange(fixture, request: line(request))
      exchanged.fd.try { |descriptor| LibC.close(descriptor) }

      assert(exchanged.reply.ok)
      assert(fixture.commands == [
        Commands.up(UTUN9),
        Commands.add_address(v4(2), name: UTUN9),
        Commands.add_route(route("10.99.0.0/16"), name: UTUN9),
      ])
      assert(!fixture.registry.empty?)
      assert(fixture.logged?("op=create name=utun9 ok"))
    end

    test "add_route and add_address that no applying configuration allows run nothing and leave the entry" do
      fixture = HandlerFixture.new
      register(fixture)
      fixture.admission = applying([client("lab", addresses: [rule("10.1.0.0/16", peer: "10.1.0.0/16")], routes: ["10.99.0.0/16"])])

      routed = change(fixture, Protocol::AddRoute.new(name: UTUN9, route: route("10.98.0.0/16")))
      addressed = change(fixture, Protocol::AddAddress.new(name: UTUN9, address: v4(3)))

      assert(routed == Protocol::Reply.new(ok: false, error: "route 10.98.0.0/16 not allowed"))
      assert(addressed == Protocol::Reply.new(ok: false, error: "address 10.77.0.3/24 not allowed"))
      assert(fixture.commands.empty?)
      assert(!recorded?(fixture, item: route("10.98.0.0/16")))
      assert(!recorded?(fixture, item: v4(3)))
      assert(fixture.logged?("op=add_route name=utun9 failed: route 10.98.0.0/16 not allowed configs=lab"))
      assert(fixture.logged?("op=add_address name=utun9 failed: address 10.77.0.3/24 not allowed configs=lab"))
    end

    test "a denied change of a device the daemon does not know gets UNKNOWN_DEVICE and runs nothing" do
      fixture = HandlerFixture.new
      register(fixture)
      fixture.admission = applying([client("lab", addresses: [] of Config::AddressRule, routes: ["10.99.0.0/16"])])

      reply = change(fixture, Protocol::AddRoute.new(name: Tunnelgeist::InterfaceName.new("utun8"), route: route("10.98.0.0/16")))

      assert(reply.error == Protocol::UNKNOWN_DEVICE)
      assert(fixture.commands.empty?)
    end

    test "add_route allowed by one of the applying configurations runs the command" do
      fixture = HandlerFixture.new
      register(fixture)
      fixture.admission = applying([
        client("lab", addresses: [] of Config::AddressRule, routes: ["10.99.0.0/16"]),
        client("wide", addresses: [] of Config::AddressRule, routes: ["10.0.0.0/8"]),
      ])

      reply = change(fixture, Protocol::AddRoute.new(name: UTUN9, route: route("10.98.0.0/16")))

      assert(reply == Protocol::Reply.new(ok: true))
      assert(fixture.commands == [Commands.add_route(route("10.98.0.0/16"), name: UTUN9)])
      assert(recorded?(fixture, item: route("10.98.0.0/16")))
    end

    test "remove_route and remove_address are not judged by the configurations" do
      fixture = HandlerFixture.new
      register(fixture)
      fixture.admission = applying([client("none", addresses: [] of Config::AddressRule, routes: [] of String)])

      routed = change(fixture, Protocol::RemoveRoute.new(name: UTUN9, route: route("10.99.0.0/16")))
      addressed = change(fixture, Protocol::RemoveAddress.new(name: UTUN9, address: v4(2)))

      assert(routed.ok)
      assert(addressed.ok)
      assert(!recorded?(fixture, item: route("10.99.0.0/16")))
      assert(!recorded?(fixture, item: v4(2)))
    end

    test "a request line over the limit gets an error reply" do
      fixture = HandlerFixture.new
      done = Channel(Nil).new

      exchanged = exchange(fixture, request: nil) do |client|
        spawn do
          client.write(Bytes.new(70_000, 'x'.ord.to_u8))
        rescue IO::Error
          # The handler replies and closes the socket before the whole line is
          # written, so the write fails; that is the case under test.
        ensure
          done.send(nil)
        end
      end
      done.receive
      reply = exchanged.reply

      assert(reply.ok == false)
      assert(reply.error.to_s.includes?("longer than 65536 bytes"))
      assert(fixture.create_calls.empty?)
    end

    test "a request that does not arrive in time gets an error reply" do
      fixture = HandlerFixture.new
      handler = fixture.handler(request_timeout: 100.milliseconds)

      started = Time.instant
      reply = exchange(fixture, request: nil, handler: handler).reply

      assert(!reply.ok)
      assert(reply.error.to_s.includes?("within"))
      assert(started.elapsed < 2.seconds)
    end

    test "a request dripped slower than the timeout allows gets an error reply at the deadline" do
      fixture = HandlerFixture.new
      handler = fixture.handler(request_timeout: 100.milliseconds)
      done = Channel(Nil).new
      stop = false

      started = Time.instant
      exchanged = exchange(fixture, request: nil, handler: handler) do |client|
        spawn do
          50.times do
            break if stop
            client.write(Bytes[' '.ord.to_u8])
            sleep 40.milliseconds
          end
        rescue IO::Error
          # The handler closes the socket at its deadline while the writer is
          # still dripping, so the next write fails; that is the case under test.
        ensure
          done.send(nil)
        end
      end
      elapsed = started.elapsed
      stop = true
      done.receive
      reply = exchanged.reply

      assert(!reply.ok)
      assert(reply.error.to_s.includes?("within"))
      assert(elapsed < 500.milliseconds)
    end

    test "malformed JSON and an empty connection get error replies" do
      fixture = HandlerFixture.new

      malformed = exchange(fixture, request: "{\"version\": 1,\n").reply
      empty = exchange(fixture, request: "", &.close_write).reply

      assert(!malformed.ok)
      assert(malformed.error.to_s.starts_with?("malformed JSON"))
      assert(!empty.ok)
      assert(fixture.create_calls.empty?)
    end

    test "a request that is not valid UTF-8 gets an error reply" do
      fixture = HandlerFixture.new
      line = %({"version": 1, "op": "create", "name": "utun\xC3", "mtu": 1400, "addresses": [], "routes": []}\n)

      reply = exchange(fixture, request: line).reply

      assert(!reply.ok)
      assert(reply.error == "request is not valid UTF-8")
      assert(fixture.create_calls.empty?)
    end

    # The admission limits (RF3).

    # The effective uid of this process, which the handler reads as the
    # peer of every connection here.
    def own_uid : UInt32
      left, right = UNIXSocket.pair
      begin
        Tunnelgeist::Peer.of(left).uid
      ensure
        left.close
        right.close
      end
    end

    def empty_create : Protocol::Create
      Protocol::Create.new(name: nil, mtu: 1_280, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix)
    end

    # A fixture whose registry keeps one device per user and four in total.
    def limited_fixture : HandlerFixture
      HandlerFixture.new(Tunnelgeist::Registry.new(max_devices: 4, max_devices_per_user: 1))
    end

    # Whether the registry of *fixture* has a device slot free for this
    # process's user; a slot it reserves is released again.
    def slot_free?(fixture : HandlerFixture) : Bool
      reservation = fixture.registry.reserve(own_uid)
      return false if reservation.is_a?(Tunnelgeist::Registry::Rejection)

      fixture.registry.release(reservation)
      true
    end

    # Starts *count* connections that *handler* serves in fibers and that
    # send nothing, and returns once *fixture* admitted their peers; each
    # channel receives once its connection is served.
    def open_idle_connections(fixture : HandlerFixture, *, handler : Tunnelgeist::Handler, clients : Array(UNIXSocket),
                              count : Int32) : Array(Channel(Nil | Exception))
      admitted = fixture.peers.size
      served = Array.new(count) do
        client, server = UNIXSocket.pair
        clients << client
        later { handler.handle(server) }
      end
      promptly do
        until fixture.peers.size == admitted + count
          sleep 1.millisecond
        end
      end
      served
    end

    test "the ninth connection of one user is refused before its admission is checked" do
      fixture = HandlerFixture.new
      handler = fixture.handler
      clients = [] of UNIXSocket
      begin
        served = open_idle_connections(fixture, handler: handler, clients: clients, count: 8)

        refused = exchange(fixture, request: nil, handler: handler).reply

        assert(Tunnelgeist::Handler::MAX_CONNECTIONS_PER_USER == 8)
        assert(refused == Protocol::Reply.new(ok: false, error: "too many connections for uid #{own_uid}"))
        assert(fixture.peers.size == 8)
        assert(fixture.logged?("uid=#{own_uid} pid=#{Process.pid} refused check=connections"))
      ensure
        clients.each(&.close)
      end
      served.try &.each { |done| awaited(done) }
    end

    test "a connection that ends frees its place for the next connection of the user" do
      fixture = HandlerFixture.new
      handler = fixture.handler(max_connections_per_user: 1)
      clients = [] of UNIXSocket
      begin
        served = open_idle_connections(fixture, handler: handler, clients: clients, count: 1)
        refused = exchange(fixture, request: nil, handler: handler).reply
        clients[0].close
        awaited(served[0])

        admitted = exchange(fixture, request: "not json\n", handler: handler).reply

        assert(refused.error == "too many connections for uid #{own_uid}")
        assert(!admitted.ok)
        assert(admitted.error.to_s.starts_with?("malformed JSON"))
        assert(fixture.peers.size == 2)
      ensure
        clients.each(&.close)
      end
    end

    test "a create over the user's device limit is refused before the device exists" do
      fixture = limited_fixture
      first = exchange(fixture, request: line(empty_create))
      first.fd.try { |descriptor| LibC.close(descriptor) }

      second = exchange(fixture, request: line(empty_create)).reply

      assert(first.reply.ok)
      assert(second == Protocol::Reply.new(ok: false, error: "device limit of 1 reached for uid #{own_uid}"))
      assert(fixture.create_calls.size == 1)
      assert(fixture.commands.size == 1)
      assert(fixture.logged?("op=create name=- failed: device limit of 1 reached for uid #{own_uid}"))
    end

    test "a create over the total device limit is refused before the device exists" do
      fixture = HandlerFixture.new(Tunnelgeist::Registry.new(max_devices: 1, max_devices_per_user: 1))
      TunnelgeistRegistrations.register(fixture.registry, UTUN8, index: 20_u32, owner: own_uid + 1)

      reply = exchange(fixture, request: line(empty_create)).reply

      assert(reply == Protocol::Reply.new(ok: false, error: "device limit of 1 reached"))
      assert(fixture.create_calls.empty?)
    end

    test "of two creates at the device limit whose commands run at the same time, only the first gets a device" do
      fixture = limited_fixture
      gate = Channel(Nil).new
      started = Channel(Array(String)).new(4)
      hold_utun9_commands(fixture, gate: gate, started: started)
      first = later { exchange(fixture, request: line(empty_create)) }
      assert(promptly { started.receive } == Commands.up(UTUN9))

      second = promptly { exchange(fixture, request: line(empty_create)).reply }
      gate.send(nil)
      created = awaited(first)
      created.fd.try { |descriptor| LibC.close(descriptor) }

      assert(second.error == "device limit of 1 reached for uid #{own_uid}")
      assert(created.reply.ok)
      assert(fixture.create_calls.size == 1)
      assert(!slot_free?(fixture))
    end

    test "a create whose command fails frees its device slot" do
      fixture = limited_fixture
      fixture.failing = "/sbin/ifconfig"

      reply = exchange(fixture, request: line(empty_create)).reply

      assert(!reply.ok)
      assert(slot_free?(fixture))
    end

    test "a create whose interface has no index frees its device slot" do
      fixture = limited_fixture
      fixture.indexes.clear

      reply = exchange(fixture, request: line(empty_create)).reply

      assert(!reply.ok)
      assert(slot_free?(fixture))
    end

    test "a create whose device creator fails frees its device slot" do
      fixture = limited_fixture
      fixture.create_error = IO::Error.from_os_error("Cannot connect to utun9", Errno::EBUSY)

      reply = exchange(fixture, request: line(empty_create)).reply

      assert(!reply.ok)
      assert(slot_free?(fixture))
    end

    test "a create whose reply cannot be sent frees its device slot" do
      fixture = limited_fixture
      client, server = UNIXSocket.pair
      client.write(line(empty_create).to_slice)
      fixture.on_create = -> { client.close }

      fixture.handler.handle(server)

      assert(fixture.registry.empty?)
      assert(fixture.logged?("reply not sent"))
      assert(slot_free?(fixture))
    end

    test "a change that finds the interface index changed frees the device slot of the entry it removes" do
      fixture = limited_fixture
      TunnelgeistRegistrations.register(fixture.registry, UTUN9, index: 21_u32, owner: own_uid)
      fixture.indexes[UTUN9] = 22_u32
      before = slot_free?(fixture)

      reply = change(fixture, Protocol::AddRoute.new(name: UTUN9, route: route("10.98.0.0/16")))

      assert(!before)
      assert(reply.error == Protocol::UNKNOWN_DEVICE)
      assert(slot_free?(fixture))
    end
  {% end %}
end
