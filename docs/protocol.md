# Protocol

The wire protocol between a client and the `tunnelgeist` daemon. The daemon is
the only process that runs as root: it opens utun devices, configures them and
passes the open device to the client. A client library speaks this protocol;
this document is all a client in another language needs.

## Transport

The daemon listens on the Unix stream socket `/var/run/tunnelgeist.sock`. A
connection carries one request and one reply, then closes.

- A request is one line of JSON in UTF-8, ended by a newline, at most 64 KiB
  (65,536 bytes). A longer line, or one that is not valid UTF-8, gets an error
  reply.
- The daemon reads the whole request within 5 seconds. A slower request gets an
  error reply.
- A reply is one line of JSON: `{"ok": true, ...}` on success or
  `{"ok": false, "error": "MESSAGE"}` on failure. Fields that have no value are
  left out.
- Every request carries `"version": 1` and an `"op"`. Unknown fields, in the
  request and in an address, are rejected by name.
- A request that changes a device carries the device's descriptor; see
  [Changing a device](#changing-a-device). The daemon closes a descriptor that
  comes with a `create`, and refuses any request whose line comes with more
  than one descriptor, as soon as the second arrives.

In the examples below, a line with an `"op"` is a request and any other line is
a reply. Both are printed exactly as the library writes them.

## Authorization

The socket is owned by root and the daemon's group (default `tunnelgeist`),
mode 0660. Before it reads the request, the daemon takes the peer's audit token
once and checks it, whatever the socket mode is: the peer must be a member of
the configured group and at least one of the daemon's client configurations
must apply to it, by its user, its groups or its code signature. A peer that
fails gets one reply and the connection closes without the request being read:

<!-- dprint-ignore -->
```json
{"ok":false,"error":"not permitted: not in group GROUP or not allowed by a client configuration"}
```

The reply does not say which check failed; the daemon's log does.

The client configurations that apply to the peer making a request also decide
which addresses and routes it may ask for: `create` checks all of its addresses
and routes before anything happens, `add_address` and `add_route` check their
item before the command runs, and `remove_address` and `remove_route` are not
checked. An item that no configuration applying to the peer allows gets one of
these errors, which name the first refused item: the address with its prefix
length or the route prefix, in canonical form, so an IPv6 item comes back
compressed:

<!-- dprint-ignore -->
```json
{"ok":false,"error":"address 10.77.0.2/24 not allowed"}
{"ok":false,"error":"route 10.99.0.0/16 not allowed"}
```

The judgment uses the peer making the request, not the one that created the
device: a process that holds a device's descriptor may only add what its own
configurations allow.

## Changing a device

`add_address`, `remove_address`, `add_route` and `remove_route` change a device
the daemon created. Each request line is sent in one `sendmsg` that carries the
device's open descriptor as `SCM_RIGHTS` ancillary data, exactly one, the way
the `create` reply carries it to the client. The client keeps its own copy.

The daemon tells the device of the descriptor by the socket's peer address
(`getpeername`): a utun descriptor is a kernel control socket whose
`sockaddr_ctl` has the `sc_id` of the control `com.apple.net.utun_control` (as
`CTLIOCGINFO` gives it), and its unit `sc_unit` names `utun<sc_unit - 1>`. The
daemon refuses the request before it looks up the device when the request
carries no descriptor, more than one, one that is not a utun device, or the
descriptor of another device than the request's `name`:

<!-- dprint-ignore -->
```json
{"ok":false,"error":"request must carry the device's descriptor"}
{"ok":false,"error":"request must carry only the device's descriptor"}
{"ok":false,"error":"descriptor is not a utun device"}
{"ok":false,"error":"descriptor is utun8, not utun7"}
```

The daemon holds the descriptor until the change is made and recorded, and
closes it before it replies, also when the change fails. While it holds it, the
kernel cannot remove the interface and give its name to a new device, so the
command changes the device the client holds. Once the daemon has closed it, the
client's own copy again decides how long the device lives.

The descriptor is the only credential a change needs: any process the daemon
admits that holds it may change the device, within what its own client
configurations allow. A client lets another process change its device by
passing it the descriptor, over a Unix socket or by inheritance.

## Operations

### create

Opens a utun device, brings it up, adds the addresses and routes and replies
with its name. `name` is `"utunN"` or `null` to let the kernel pick the first
free one; `mtu` is 1280 to 65535; `addresses` and `routes` may be empty. An
address is `{"address": "10.77.0.2", "prefix": 24, "peer": "10.77.0.1"}` (IPv4,
with a peer) or `{"address": "fd77::2", "prefix": 64}` (IPv6, without one). A
route is a prefix such as `"10.99.0.0/16"`.

Request:

<!-- dprint-ignore -->
```json
{"version":1,"op":"create","name":null,"mtu":1400,"addresses":[{"address":"10.77.0.2","prefix":24,"peer":"10.77.0.1"},{"address":"fd77::2","prefix":64}],"routes":["10.99.0.0/16","fd99::/48"]}
```

Reply:

<!-- dprint-ignore -->
```json
{"ok":true,"name":"utun7"}
```

The reply carries the open device as one file descriptor, attached to the same
message as `SCM_RIGHTS` ancillary data. The daemon closes its own copy
afterwards. The descriptor is blocking and the daemon sets close-on-exec on its
own copy only: setting close-on-exec on the received descriptor is the client's
job. If any step fails, the daemon closes the descriptor, which removes the
interface, registers nothing and replies with an error and no descriptor.

### add_address and remove_address

Request:

<!-- dprint-ignore -->
```json
{"version":1,"op":"add_address","name":"utun7","address":{"address":"fd77::2","prefix":64}}
```

Reply:

<!-- dprint-ignore -->
```json
{"ok":true}
```

`remove_address`:

<!-- dprint-ignore -->
```json
{"version":1,"op":"remove_address","name":"utun7","address":{"address":"fd77::2","prefix":64}}
```

The kernel tells the addresses of a device apart by their local address, and so
does the daemon: `add_address` is refused when the device already has the local
address, also with another prefix length or peer. `remove_address` accepts only
an address the daemon added for that device, with the same prefix length and
peer.

<!-- dprint-ignore -->
```json
{"ok":false,"error":"address 10.77.0.2 already on utun7"}
```

### add_route and remove_route

Request:

<!-- dprint-ignore -->
```json
{"version":1,"op":"add_route","name":"utun7","route":"10.99.0.0/16"}
```

Reply:

<!-- dprint-ignore -->
```json
{"ok":true}
```

`remove_route`:

<!-- dprint-ignore -->
```json
{"version":1,"op":"remove_route","name":"utun7","route":"10.99.0.0/16"}
```

`remove_route` accepts only a route the daemon added for that device. A route
of the same prefix on another interface is never touched: the daemon deletes
the route only when the kernel reports it on this device. When the route is
already gone from the device, nothing is deleted and the reply is ok. Adding a
route the device already has is an error.

## Validation

Every request is checked before anything happens, and the daemon answers a
request it rejects with an error reply.

- `version` is the integer 1; `op` is one of the five operations above.
- `name` is `utun` followed by a unit number without leading zeros.
- `mtu` is an integer from 1280 to 65535.
- Addresses and routes are IPv4 or IPv6 literals without a zone (`%`). A route
  is `ADDRESS/LENGTH` with a length that has no leading zero and no host bits
  set: `10.99.0.0/16` is valid, `10.99.0.1/16` is not.
- The prefix length of an address is 0 to 32 (IPv4) or 0 to 128 (IPv6). An IPv4
  address has a `peer` of the same family; an IPv6 address has none.
- A `create` has at most 16 addresses and 64 routes, and a device has at most
  that many in total, counting what it already has.
- A `create` names each local address once; one listed twice is refused, as in
  `address 10.77.0.2 listed twice`.
- Every field has its type: a string where a string is expected, an integer
  where an integer is expected. Nothing but the fields listed is accepted.

A failed `ifconfig` or `route` turns into an error reply that carries the
program, its exit status and its standard error, such as
`/sbin/route exited 1: route: File exists`; of a longer standard error the
first 4 KiB (4,096 bytes) are kept, followed by `… (truncated)`. A command
still running after 10 seconds is stopped, and the reply names the program and
the limit, as in `ifconfig timed out after 10 s`. The daemon runs at most 4
commands at once; a further one waits until one of them ends. A client error
never stops the daemon.

## Limits

The daemon bounds the connections it serves and the devices it keeps, in total
and per user, the peer's effective user ID:

| Limit                    | Value | Over the limit                                                    |
| ------------------------ | ----- | ----------------------------------------------------------------- |
| Connections being served | 64    | the next connection waits in the socket's queue until one ends    |
| Connections of one user  | 8     | `too many connections for uid U`, before the authorization checks |
| Devices                  | 128   | `create` fails with `device limit of 128 reached`                 |
| Devices of one user      | 16    | `create` fails with `device limit of 16 reached for uid U`        |

A device counts against the user whose `create` made it from the moment the
`create` is checked until the kernel removes its interface, or until its
`create` fails or its reply cannot be sent. Before the daemon refuses a
`create` for a limit, it looks up the interfaces of the devices that count
against that limit and forgets those the kernel no longer has, also when it
missed their removal. A refused `create` opens no device.

<!-- dprint-ignore -->
```json
{"ok":false,"error":"too many connections for uid 501"}
{"ok":false,"error":"device limit of 128 reached"}
{"ok":false,"error":"device limit of 16 reached for uid 501"}
```

## Unknown devices

A change whose descriptor passes the checks above but names a device the daemon
does not know, one it did not create or one that is gone, gets:

<!-- dprint-ignore -->
```json
{"ok":false,"error":"unknown device"}
```
