![tunnelgeist, utun without root](artwork/tunnelgeist-banner.jpg)

# tunnelgeist

On macOS only root can create a utun device, give it addresses or route to it.
tunnelgeist is a root daemon that does this for programs that do not run as
root, within the addresses and routes its configuration allows each of them. It
comes with a Crystal client library for those programs.

- **utun devices without root.** A program asks the daemon for a device and
  gets the open descriptor; the interface goes away when the program closes it
  or exits.
- **Per-client limits.** Only members of one group may ask. A root-owned JSON
  configuration narrows that down by user, group and code signature, and sets
  the addresses and routes each client may use.
- **On demand.** launchd starts the daemon on the first request, and it exits
  after 30 idle seconds with no device open.
- **Crystal client library.** `Tunnelgeist::Client` creates devices and changes
  their addresses and routes; [docs/protocol.md](docs/protocol.md) describes
  the wire protocol for clients in other languages.

## Usage

A client configuration in `/usr/local/etc/tunnelgeist/clients.d/vm.json` lets
the user with uid 501 give a device an address in `192.168.64.0/24` and route
`192.168.65.0/24` to it:

```json
{
    "name": "vm",
    "users": ["501"],
    "addresses": [{ "network": "192.168.64.0/24", "peer": "192.168.64.0/24" }],
    "routes": ["192.168.65.0/24"]
}
```

A program running as that user asks the daemon for such a device:

```crystal
require "tunnelgeist"

client = Tunnelgeist::Client.new
device = client.create(
  addresses: [
    Tunnelgeist::Address.new(
      Socket::IPAddress.new("192.168.64.1", 0), prefix: 24, peer: Socket::IPAddress.new("192.168.64.2", 0)),
  ],
  routes: [Tunnelgeist::Prefix.parse("192.168.65.0/24")],
)
puts "#{device.name} is up" # read and write packets on device.fd
```

The [examples](examples) directory has a complete configuration and client
program. [docs/configuration.md](docs/configuration.md) describes the
configuration, and [docs/client.md](docs/client.md) the client library.

## Installation

tunnelgeist needs macOS; Homebrew has builds for Apple Silicon Macs:

```sh
brew install jochenseeber/tap/tunnelgeist
sudo tunnelgeist install
```

Then add each user who may create devices to the group `tunnelgeist`.
[INSTALL.md](INSTALL.md) describes what `install` does, the group, building
from source and uninstalling.

## Contributing

See [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md). Everyone taking part follows
the [code of conduct](CODE_OF_CONDUCT.md).

## License

MIT, see [LICENSE.txt](LICENSE.txt).
