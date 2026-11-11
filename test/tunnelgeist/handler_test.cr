require "../test_helper"
require "socket"
require "../../src/tunnelgeist/fd_passing"
require "../../src/tunnelgeist/handler"
require "../../spec/tunnelgeist/support/client_configs"

# The request handler with the kernel's own lookup of a descriptor's
# interface name, `Device.name_of`; the other collaborators are fakes.
describe TunnelgeistHandler do
  {% if flag?(:darwin) %}
    alias Protocol = Tunnelgeist::Protocol

    UTUN9 = Tunnelgeist::InterfaceName.new("utun9")

    test "a change that carries the end of a Unix socket pair is refused as no utun device and runs nothing" do
      registry = Tunnelgeist::Registry.new
      key = registry.register(UTUN9, index: 21_u32, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix) { }
      commands = [] of Array(String)
      handler = Tunnelgeist::Handler.new(registry,
        create_device: ->(_name : Tunnelgeist::InterfaceName?, _mtu : Int32) : Tunnelgeist::Device::Utun { raise "no device in this test" },
        run: ->(argv : Array(String)) { commands << argv; Tunnelgeist::CommandRunner::Result.new(exit_status: 0, output: "", error: "") },
        admit: ->(_peer : Tunnelgeist::Peer) { TunnelgeistClientConfigs.open_admission },
        group: "tunnelgeist",
        interface_index: ->(_name : Tunnelgeist::InterfaceName) { 21_u32 },
        log: Log.new("tunnelgeist", Log::MemoryBackend.new, :debug))
      stranger, other = UNIXSocket.pair
      client, server = UNIXSocket.pair
      begin
        request = Protocol::AddRoute.new(name: UTUN9, key: key, route: Tunnelgeist::Prefix.parse("10.98.0.0/16"))
        Tunnelgeist::FdPassing.send(client, data: "#{request.to_json}\n".to_slice, fd: stranger.fd)
        stranger.close
        handler.handle(server)

        reply = Protocol::Reply.parse(client.gets.to_s)
        assert(reply == Protocol::Reply.new(ok: false, error: "descriptor is not a utun device"))
        assert(commands.empty?)
        # Every copy of the stranger's end is closed, so its peer reads end of
        # file.
        other.read_timeout = 1.second
        assert(other.read(Bytes.new(1)) == 0)
      ensure
        [stranger, other, client, server].each(&.close)
      end
    end
  {% end %}
end
