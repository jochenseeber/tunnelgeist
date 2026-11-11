# Examples

## Configuration

`config/` is a complete daemon configuration. Copy it to
`/usr/local/etc/tunnelgeist/` with `sudo`, owned by root and writable by no one
else, and reload the daemon; [docs/configuration.md](../docs/configuration.md)
describes every field.

- `config/config.json` is the main file. It names the socket and the main group
  `tunnelgeist`, includes every `clients.d/*.json`, and holds one client
  configuration, `admins`. It lets the members of `tunnelgeist` who are also
  members of `admin` use any address and route in `10.0.0.0/8` and `fc00::/7`.
- `config/clients.d/vpn.json` admits only a program signed with the Developer
  ID of team `ABCDE12345` and the identifier `com.example.vpn`, whoever runs
  it. It allows addresses in `10.8.0.0/24` and `fd00:8::/64` and routes into
  two IPv4 networks and one IPv6 network.
- `config/clients.d/vm.json` admits the user with uid 501, and only while that
  user is a member of `staff`. It allows one IPv4 network and one route, for a
  virtual machine's network.

`spec/tunnelgeist/examples_spec.cr` loads these files with the daemon's loader,
so `rake spec` fails when one of them stops loading.

## Client library

`client.cr` asks the daemon for a device with an address and a route, adds and
removes a second route, once through the device and once through a handle made
from its name and key, and closes the device. Its addresses and routes are
allowed by `config/clients.d/vm.json` and by the starter configuration
`tunnelgeist install` writes.

In a program that depends on the shard, `require "tunnelgeist"` finds the
library. Inside this repository, `rake examples:build` builds the example
against the library in `src/`:

```sh
rake examples:build
.work/examples/client
```
