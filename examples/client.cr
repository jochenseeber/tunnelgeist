# Asks the tunnelgeist daemon for a utun device, adds a route to it and closes
# it again. The addresses and routes lie inside what `config/clients.d/vm.json`
# and the starter configuration allow.
require "tunnelgeist"

client = Tunnelgeist::Client.new # /var/run/tunnelgeist.sock

begin
  device = client.create(
    mtu: 1400,
    addresses: [
      Tunnelgeist::Address.new(
        Socket::IPAddress.new("192.168.64.1", 0),
        prefix: 24,
        peer: Socket::IPAddress.new("192.168.64.2", 0),
      ),
    ],
    routes: [Tunnelgeist::Prefix.parse("192.168.65.0/24")],
  )
rescue error : Tunnelgeist::Client::Error
  STDERR.puts "#{error.reason}: #{error.message}"
  exit 1
end

puts "#{device.name} is up with descriptor #{device.fd}"

# Each change is one request that carries the device's descriptor.
device.add_route(Tunnelgeist::Prefix.parse("192.168.65.128/25"))
device.remove_route(Tunnelgeist::Prefix.parse("192.168.65.128/25"))

# Closing the descriptor removes the interface.
LibC.close(device.fd)
