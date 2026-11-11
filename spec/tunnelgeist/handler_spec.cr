require "../spec_helper"
require "../../src/tunnelgeist/handler"
require "./support/client_configs"

# The request handler of the root helper (UA5, UP1 to UP7), with every
# collaborator replaced: the device creator, the command runner, the
# authorizer's admission and the interface index lookup.
describe TunnelgeistHandler do
  {% if flag?(:darwin) %}
    alias Protocol = Tunnelgeist::Protocol
    alias Commands = Tunnelgeist::Commands
    alias FdPassing = Tunnelgeist::FdPassing
    alias Admission = Tunnelgeist::Authorizer::Admission
    alias Config = Tunnelgeist::Config
    alias Reason = Tunnelgeist::Refusal::Reason

    include TunnelgeistClientConfigs

    REFUSAL = "not permitted: not in group tunnelgeist or not allowed by a client configuration"
    UTUN9   = Tunnelgeist::InterfaceName.new("utun9")

    # One call of the fake device creator.
    record CreateCall, name : Tunnelgeist::InterfaceName?, mtu : Int32

    # One call of the drain of the departure watcher: whether the registry
    # was empty and how many commands had run.
    record DrainCall, registry_empty : Bool, commands_run : Int32

    # A reply line and the descriptor that came with it, if any.
    record ReplyExchange, reply : Protocol::Reply, fd : Int32?

    # A handler on fakes that record what it asked of them.
    class HandlerFixture
      getter registry = Tunnelgeist::Registry.new
      getter commands = [] of Array(String)
      getter backend = Log::MemoryBackend.new
      # The descriptors the fake device creator handed out.
      getter device_fds = [] of Int32
      getter create_calls = [] of CreateCall
      getter drain_calls = [] of DrainCall
      # The peers the fake authorizer was asked about.
      getter peers = [] of Tunnelgeist::Peer
      # The program whose runs fail, with exit status 1.
      property failing : String? = nil
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

      def handler(request_timeout : Time::Span = Protocol::REQUEST_TIMEOUT) : Tunnelgeist::Handler
        Tunnelgeist::Handler.new(registry,
          create_device: ->(name : Tunnelgeist::InterfaceName?, mtu : Int32) { create_device(name, mtu: mtu) },
          run: ->(argv : Array(String)) { run(argv) },
          admit: ->(peer : Tunnelgeist::Peer) { admit(peer) },
          group: "tunnelgeist",
          interface_index: ->(name : Tunnelgeist::InterfaceName) { @indexes[name]? || 0_u32 },
          request_timeout: request_timeout,
          drain_departures: -> { record_drain },
          log: Log.new("tunnelgeist", backend, :debug))
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
        if argv[0] == Commands::ROUTE && argv[2] == "get"
          output = @route_get
          reply = output ? result(0, output: output, error: "") : result(1, output: "", error: "route: writing to routing socket: not in table\n")
          return reply
        end
        argv[0] == @failing ? result(1, output: "", error: "#{File.basename(argv[0])}: File exists\n") : result(0, output: "", error: "")
      end

      private def result(exit_status : Int32, *, output : String, error : String) : Tunnelgeist::CommandRunner::Result
        Tunnelgeist::CommandRunner::Result.new(exit_status: exit_status, output: output, error: error)
      end

      # Every text the log captured, to search for a key.
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

    # Sends *request* (when given), runs the handler on the other end and
    # returns the reply and the descriptor that came with it. The handler's
    # socket must be closed afterwards.
    def exchange(fixture : HandlerFixture, *, request : String?, handler = fixture.handler, & : UNIXSocket ->) : ReplyExchange
      client, server = UNIXSocket.pair
      begin
        client.write(request.to_slice) if request
        yield client
        handler.handle(server)
        assert(server.closed?)
        read_reply(client)
      ensure
        client.close
      end
    end

    def exchange(fixture : HandlerFixture, *, request : String?, handler = fixture.handler) : ReplyExchange
      exchange(fixture, request: request, handler: handler) { }
    end

    # Whether the registry refuses *key* for utun9.
    def refused_key?(fixture : HandlerFixture, *, key : Tunnelgeist::Key) : Bool
      fixture.registry.with_entry(UTUN9, key: key) { } == Tunnelgeist::Registry::Rejection.unknown_device
    end

    # Whether the entry of utun9 has recorded *item*: it may be removed and
    # may not be added again. `Entry` keeps its arrays to itself, so its
    # checks are what shows them. Raises when the registry refuses *key*, so
    # a refusal cannot pass for an item that is not recorded.
    def recorded?(fixture : HandlerFixture, *, key : Tunnelgeist::Key, item : Tunnelgeist::Address | Tunnelgeist::Prefix) : Bool
      result = fixture.registry.with_entry(UTUN9, key: key) do |entry|
        case item
        in Tunnelgeist::Address
          entry.check_remove_address(item).nil? && !entry.check_add_address(item).nil?
        in Tunnelgeist::Prefix
          entry.check_remove_route(item).nil? && !entry.check_add_route(item).nil?
        end
      end
      raise "the registry refused the key of utun9" if result.is_a?(Tunnelgeist::Registry::Rejection)

      result
    end

    def register(fixture : HandlerFixture) : Tunnelgeist::Key
      fixture.registry.register(UTUN9, index: 21_u32, addresses: [v4(2)], routes: [route("10.99.0.0/16")]) { }
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
        key = reply.key!
        assert(key.to_s.matches?(/\A[A-Za-z0-9_-]{43}\z/))
        assert(fd)
        assert(fixture.create_calls == [CreateCall.new(name: nil, mtu: 1_400)])
        assert(fixture.commands == [
          Commands.up(UTUN9),
          Commands.add_address(v4(2), name: UTUN9),
          Commands.add_route(route("10.99.0.0/16"), name: UTUN9),
          Commands.add_route(route("fd99::/48"), name: UTUN9),
        ])
        assert(fixture.registry.with_entry(UTUN9, key: key, &.index) == 21_u32)
        assert(recorded?(fixture, key: key, item: route("10.99.0.0/16")))
        assert(recorded?(fixture, key: key, item: route("fd99::/48")))
        assert(fixture.logged?("op=create name=utun9"))
        assert(!fixture.logged?(key.to_s))
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
      old = register(fixture)
      fixture.indexes[UTUN9] = 23_u32

      exchanged = exchange(fixture, request: line(Protocol::Create.new(name: nil, mtu: 1_280, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix)))
      reply = exchanged.reply
      fd = exchanged.fd
      fd.try { |descriptor| LibC.close(descriptor) }

      assert(reply.ok)
      fresh = reply.key!
      old_refused = refused_key?(fixture, key: old)
      assert(old_refused)
      assert(fixture.registry.with_entry(UTUN9, key: fresh, &.index) == 23_u32)
      warning = fixture.backend.entries.find { |entry| entry.severity.warn? && entry.message.includes?("replaced") }
      assert(warning)
      assert(warning.try(&.message.ends_with?("op=create name=utun9 replaced stale entry: interface index 21 now 23")))
      assert(!fixture.logged?(old.to_s))
      assert(!fixture.logged?(fresh.to_s))
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

    test "add_route and remove_route with the key run the command and update the entry" do
      fixture = HandlerFixture.new
      key = register(fixture)

      added = exchange(fixture, request: line(Protocol::AddRoute.new(name: UTUN9, key: key, route: route("10.98.0.0/16")))).reply
      removed = exchange(fixture, request: line(Protocol::RemoveRoute.new(name: UTUN9, key: key, route: route("10.99.0.0/16")))).reply

      assert(added == Protocol::Reply.new(ok: true))
      assert(removed == Protocol::Reply.new(ok: true))
      assert(fixture.commands == [
        Commands.add_route(route("10.98.0.0/16"), name: UTUN9),
        Commands.get_route(route("10.99.0.0/16")),
        Commands.remove_route(route("10.99.0.0/16"), name: UTUN9),
      ])
      assert(recorded?(fixture, key: key, item: route("10.98.0.0/16")))
      assert(!recorded?(fixture, key: key, item: route("10.99.0.0/16")))
      assert(fixture.logged?("op=add_route name=utun9"))
      assert(!fixture.logged?(key.to_s))
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
        key = register(fixture)

        reply = exchange(fixture, request: line(Protocol::RemoveRoute.new(name: UTUN9, key: key, route: route("10.99.0.0/16")))).reply

        assert(reply == Protocol::Reply.new(ok: true))
        assert(fixture.commands == [Commands.get_route(route("10.99.0.0/16"))])
        assert(!recorded?(fixture, key: key, item: route("10.99.0.0/16")))
        assert(fixture.logged?("route 10.99.0.0/16 no longer on utun9, forgotten"))
      end
    end

    test "remove_route of an IPv6 route asks route get with -inet6" do
      fixture = HandlerFixture.new
      key = fixture.registry.register(UTUN9, index: 21_u32, addresses: [v4(2)], routes: [route("fd99::/48")]) { }

      reply = exchange(fixture, request: line(Protocol::RemoveRoute.new(name: UTUN9, key: key, route: route("fd99::/48")))).reply

      assert(reply.ok)
      assert(fixture.commands == [
        ["/sbin/route", "-n", "get", "-inet6", "fd99::/48"],
        Commands.remove_route(route("fd99::/48"), name: UTUN9),
      ])
    end

    test "add_address and remove_address with the key run the command and update the entry" do
      fixture = HandlerFixture.new
      key = register(fixture)

      added = exchange(fixture, request: line(Protocol::AddAddress.new(name: UTUN9, key: key, address: v4(3)))).reply
      removed = exchange(fixture, request: line(Protocol::RemoveAddress.new(name: UTUN9, key: key, address: v4(2)))).reply

      assert(added.ok)
      assert(removed.ok)
      assert(fixture.commands == [
        Commands.add_address(v4(3), name: UTUN9),
        Commands.remove_address(v4(2), name: UTUN9),
      ])
      assert(recorded?(fixture, key: key, item: v4(3)))
      assert(!recorded?(fixture, key: key, item: v4(2)))
      assert(!fixture.logged?(key.to_s))
    end

    test "a change with a wrong key or an unknown name gets UNKNOWN_DEVICE and runs nothing" do
      fixture = HandlerFixture.new
      key = register(fixture)

      wrong = exchange(fixture, request: line(Protocol::AddRoute.new(name: UTUN9, key: Tunnelgeist::Key.generate, route: route("10.98.0.0/16")))).reply
      unknown = exchange(fixture, request: line(Protocol::AddRoute.new(name: Tunnelgeist::InterfaceName.new("utun8"), key: key, route: route("10.98.0.0/16")))).reply

      assert(wrong.error == Protocol::UNKNOWN_DEVICE)
      assert(unknown.error == Protocol::UNKNOWN_DEVICE)
      assert(fixture.logged?("op=add_route name=utun9 failed: unknown device or wrong key"))
      assert(fixture.logged?("op=add_route name=utun8 failed: unknown device or wrong key"))
      assert(fixture.commands.empty?)
      assert(recorded?(fixture, key: key, item: route("10.99.0.0/16")))
      assert(!recorded?(fixture, key: key, item: route("10.98.0.0/16")))
      assert(!fixture.logged?(key.to_s))
    end

    test "a change whose interface index changed or vanished gets UNKNOWN_DEVICE and removes the entry" do
      [22_u32, 0_u32].each do |index|
        fixture = HandlerFixture.new
        key = register(fixture)
        fixture.indexes[UTUN9] = index

        reply = exchange(fixture, request: line(Protocol::RemoveRoute.new(name: UTUN9, key: key, route: route("10.99.0.0/16")))).reply

        assert(reply.error == Protocol::UNKNOWN_DEVICE)
        assert(fixture.registry.empty?)
        assert(fixture.commands.empty?)
        assert(!fixture.logged?(key.to_s))
      end
    end

    test "a change the entry refuses runs no command" do
      fixture = HandlerFixture.new
      key = register(fixture)

      duplicate = exchange(fixture, request: line(Protocol::AddRoute.new(name: UTUN9, key: key, route: route("10.99.0.0/16")))).reply
      foreign = exchange(fixture, request: line(Protocol::RemoveAddress.new(name: UTUN9, key: key, address: v4(5)))).reply

      assert(duplicate.error == "route 10.99.0.0/16 already on utun9")
      assert(foreign.error == "address 10.77.0.5 was not added by the helper")
      assert(fixture.logged?("op=add_route name=utun9 failed: route 10.99.0.0/16 already on utun9"))
      assert(fixture.logged?("op=remove_address name=utun9 failed: address 10.77.0.5 was not added by the helper"))
      assert(fixture.commands.empty?)
    end

    test "a failed change command replies the error and leaves the entry unchanged" do
      fixture = HandlerFixture.new
      fixture.failing = "/sbin/route"
      key = register(fixture)

      reply = exchange(fixture, request: line(Protocol::RemoveRoute.new(name: UTUN9, key: key, route: route("10.99.0.0/16")))).reply

      assert(reply.error == "/sbin/route exited 1: route: File exists")
      assert(recorded?(fixture, key: key, item: route("10.99.0.0/16")))
      assert(!recorded?(fixture, key: key, item: route("10.98.0.0/16")))
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

    test "a refused peer holding a valid key gets the same refusal and changes nothing" do
      fixture = HandlerFixture.new
      key = register(fixture)
      fixture.admission = Admission.new(clients: [] of Config::Client, refusals: [client_refusal("vpn", reason: Reason::Requirement)])

      reply = exchange(fixture, request: line(Protocol::RemoveRoute.new(name: UTUN9, key: key, route: route("10.99.0.0/16")))).reply

      assert(reply.error == REFUSAL)
      assert(fixture.commands.empty?)
      assert(recorded?(fixture, key: key, item: route("10.99.0.0/16")))
      assert(!recorded?(fixture, key: key, item: route("10.98.0.0/16")))
      assert(fixture.logged?("refused check=config vpn=requirement"))
      assert(!fixture.logged?(key.to_s))
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
      key = register(fixture)
      fixture.admission = applying([client("lab", addresses: [rule("10.1.0.0/16", peer: "10.1.0.0/16")], routes: ["10.99.0.0/16"])])

      routed = exchange(fixture, request: line(Protocol::AddRoute.new(name: UTUN9, key: key, route: route("10.98.0.0/16")))).reply
      addressed = exchange(fixture, request: line(Protocol::AddAddress.new(name: UTUN9, key: key, address: v4(3)))).reply

      assert(routed == Protocol::Reply.new(ok: false, error: "route 10.98.0.0/16 not allowed"))
      assert(addressed == Protocol::Reply.new(ok: false, error: "address 10.77.0.3/24 not allowed"))
      assert(fixture.commands.empty?)
      assert(!recorded?(fixture, key: key, item: route("10.98.0.0/16")))
      assert(!recorded?(fixture, key: key, item: v4(3)))
      assert(fixture.logged?("op=add_route name=utun9 failed: route 10.98.0.0/16 not allowed configs=lab"))
      assert(fixture.logged?("op=add_address name=utun9 failed: address 10.77.0.3/24 not allowed configs=lab"))
      assert(!fixture.logged?(key.to_s))
    end

    test "a denied change with a wrong key gets UNKNOWN_DEVICE, so the denial says nothing to a stranger" do
      fixture = HandlerFixture.new
      register(fixture)
      fixture.admission = applying([client("lab", addresses: [] of Config::AddressRule, routes: ["10.99.0.0/16"])])

      reply = exchange(fixture, request: line(Protocol::AddRoute.new(name: UTUN9, key: Tunnelgeist::Key.generate, route: route("10.98.0.0/16")))).reply

      assert(reply.error == Protocol::UNKNOWN_DEVICE)
      assert(fixture.commands.empty?)
    end

    test "add_route allowed by one of the applying configurations runs the command" do
      fixture = HandlerFixture.new
      key = register(fixture)
      fixture.admission = applying([
        client("lab", addresses: [] of Config::AddressRule, routes: ["10.99.0.0/16"]),
        client("wide", addresses: [] of Config::AddressRule, routes: ["10.0.0.0/8"]),
      ])

      reply = exchange(fixture, request: line(Protocol::AddRoute.new(name: UTUN9, key: key, route: route("10.98.0.0/16")))).reply

      assert(reply == Protocol::Reply.new(ok: true))
      assert(fixture.commands == [Commands.add_route(route("10.98.0.0/16"), name: UTUN9)])
      assert(recorded?(fixture, key: key, item: route("10.98.0.0/16")))
    end

    test "remove_route and remove_address are not judged by the configurations" do
      fixture = HandlerFixture.new
      key = register(fixture)
      fixture.admission = applying([client("none", addresses: [] of Config::AddressRule, routes: [] of String)])

      routed = exchange(fixture, request: line(Protocol::RemoveRoute.new(name: UTUN9, key: key, route: route("10.99.0.0/16")))).reply
      addressed = exchange(fixture, request: line(Protocol::RemoveAddress.new(name: UTUN9, key: key, address: v4(2)))).reply

      assert(routed.ok)
      assert(addressed.ok)
      assert(!recorded?(fixture, key: key, item: route("10.99.0.0/16")))
      assert(!recorded?(fixture, key: key, item: v4(2)))
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
  {% end %}
end
