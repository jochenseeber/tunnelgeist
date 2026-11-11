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
`Tunnelgeist::InterfaceName`), the `mtu` and `fd`, the open utun descriptor.
The descriptor belongs to the caller, who closes it; closing it removes the
interface. It is blocking and has close-on-exec set. Each packet on it starts
with a 4-byte address family header, as on any utun device. The address is the
kernel's side of the interface; for IPv4 it takes a peer, the other side's
address, and for IPv6 none. `create` also takes a `name`
(`Tunnelgeist::InterfaceName.new("utun7")`; by default any free unit). The
device has `add_address`, `remove_address`, `add_route` and `remove_route`;
each is one request that carries the device's descriptor, and the daemon
removes only what it added. The daemon checks that the descriptor is the
device's and holds it while it changes the device, so the device cannot go away
in the middle of a change; the descriptor stays open in the caller.

`InterfaceName.new` raises `ArgumentError` for text that is not `utunN`;
`InterfaceName.parse?` returns nil instead. `to_s` of a name gives its text.

## Sharing a device

Holding the descriptor is what lets a process change the device. To let another
process change it, pass it the descriptor, over a Unix socket
(`Tunnelgeist::FdPassing.send`) or by inheritance. The receiving process takes
it with `Tunnelgeist::FdPassing.receive` and reads the device's name from it
with `Tunnelgeist::Device.name_of`. For each change it connects to the daemon's
socket, builds a request such as `Tunnelgeist::Protocol::AddRoute` with that
name, sends the request's JSON line with the descriptor attached through
`FdPassing.send`, and reads the reply line with
`Tunnelgeist::Protocol::Reply.parse`, as
[Changing a device](protocol.md#changing-a-device) describes. The daemon judges
the change by that process's own client configurations. Code that wraps a
received descriptor takes the name from `Device.name_of`, never from the
caller, because the daemon refuses a descriptor of any device but the one the
request names.

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
  for the device's (see [Changing a device](protocol.md#changing-a-device)), a
  limit, such as `device limit of 16 reached for uid 501` (see
  [Limits](protocol.md#limits)), or a failed command.
- `NoDevice`: the reply to `create` carried no device.

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
- The daemon keeps at most 16 devices for one user and 128 in all, and serves
  at most 8 connections of one user at once.
- The daemon reads a request within 5 seconds, and a request is at most 64 KiB.
- The client gives up after 10 seconds (`Client#timeout`).
- The daemon exits after 30 idle seconds with no device open; launchd starts it
  again on the next request.
