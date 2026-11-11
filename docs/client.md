# Client library

`Tunnelgeist::Client` is the Crystal library a program uses to ask the
`tunnelgeist` daemon for a utun device.
[examples/client.cr](../examples/client.cr) is a complete program.

## Adding the shard

The shard needs Crystal 1.22 or later and runs on macOS only. Add it to
`shard.yml`:

```yaml
dependencies:
  tunnelgeist:
    github: jochenseeber/tunnelgeist
```

## Creating a device

`Tunnelgeist::Client` asks the daemon for a device. `require "tunnelgeist"`
loads the client and links no framework; only the daemon links Security.
`Client.new` connects to `/var/run/tunnelgeist.sock`, and `Client.new(PATH)` to
another socket.

```crystal
require "tunnelgeist"

client = Tunnelgeist::Client.new # /var/run/tunnelgeist.sock
device = client.create(
  mtu: 1280,
  addresses: [
    Tunnelgeist::Address.new(
      Socket::IPAddress.new("10.77.0.1", 0), prefix: 24, peer: Socket::IPAddress.new("10.77.0.2", 0)),
  ],
  routes: [Tunnelgeist::Prefix.parse("10.99.0.0/16")],
)

fd = device.fd # the utun descriptor; read and write packets on it
device.add_route(Tunnelgeist::Prefix.parse("10.98.0.0/16"))
puts "#{device.name} is up"
```

`create` returns a `Tunnelgeist::Client::Device` with the interface `name` (a
`Tunnelgeist::InterfaceName`), a secret `key` (a `Tunnelgeist::Key`), the `mtu`
and `fd`, the open utun descriptor. The descriptor belongs to the caller, who
closes it; closing it removes the interface. It is blocking and has
close-on-exec set. Each packet on it starts with a 4-byte address family
header, as on any utun device. The address is the kernel's side of the
interface; for IPv4 it takes a peer, the other side's address, and for IPv6
none. `create` also takes a `name` (`Tunnelgeist::InterfaceName.new("utun7")`;
by default any free unit). The device has `add_address`, `remove_address`,
`add_route` and `remove_route`; each is one request that carries the device's
descriptor and key, and the daemon removes only what it added. The daemon
checks that the descriptor is the device's and holds it while it changes the
device, so the device cannot go away in the middle of a change; the descriptor
stays open in the caller.

## Handles and keys

`client.handle`, given a device's name and key, and `device.to_handle` make a
`Tunnelgeist::Client::Handle`: the name and key without the descriptor. A
handle cannot change its device. The daemon changes a device only for a request
that carries the device's descriptor, so the four change operations of a handle
raise `Tunnelgeist::Client::Error` with reason `NoDescriptor` and send nothing;
only the `Tunnelgeist::Client::Device` that `create` returned changes the
device. `to_s` of a name or a key gives its text, and `inspect` of a key hides
it.

`InterfaceName.new` and `Key.new` raise `ArgumentError` for text that is not
`utunN` or not a key; `parse?` returns nil instead. The key stops working when
the device is gone or the daemon restarts.

## Errors

Every failure raises `Tunnelgeist::Client::Error`, an `IO::Error` whose
`reason` is a `Tunnelgeist::Client::Error::Reason`:

- `DaemonUnavailable`: the daemon is not running
  (`tunnelgeist is not running or not installed`).
- `ConnectionRefused`: the kernel refused the connection because the user is
  not in the socket's group (`not permitted`).
- `ConnectionFailed`: any other failure on the connection.
- `Timeout`: no answer within `Client#timeout`, 10 seconds by default.
- `InvalidReply`: the reply is not valid.
- `Refused`: the daemon replied with an error, whose text is the message. It is
  the refusal
  `not permitted: not in group GROUP or not allowed by a client configuration`,
  an item the configuration does not allow, such as
  `address 10.99.0.1/24 not allowed` or `route 10.99.0.0/16 not allowed` (see
  [Refusals](configuration.md#refusals)), a descriptor the daemon does not take
  for the device's (see [Changing a device](protocol.md#changing-a-device)), or
  a failed command.
- `NoDevice`: the reply to `create` carried no device.
- `NoDescriptor`: a `Handle` was asked for a change, which needs the device's
  descriptor; nothing was sent.

## Without the daemon

A caller that is root needs no daemon. `Tunnelgeist::Device.create` opens the
device itself and returns a `Tunnelgeist::Device::Utun` with the descriptor
(`fd`) and the interface name (`name`):

```crystal
device = Tunnelgeist::Device.create # or create(Tunnelgeist::InterfaceName.new("utun7"), mtu: 1400)
device.fd
device.name
```

The interface is left down and without addresses. `Tunnelgeist::Commands`
builds the `ifconfig` and `route` command lines that bring it up and give it
addresses and routes, for a caller that runs them itself; it only builds them.

## Protocol

The daemon speaks one JSON line per request and per reply over its Unix socket,
passes the descriptor with the reply to `create` and takes it back with each
change. [protocol.md](protocol.md) describes it, so a client in another
language can be written from that document alone.

## Limits

- A device allows 16 addresses and 64 routes.
- The daemon reads a request within 5 seconds, and a request is at most 64 KiB.
- The client gives up after 10 seconds (`Client#timeout`).
- The daemon exits after 30 idle seconds with no device open; launchd starts it
  again on the next request.
