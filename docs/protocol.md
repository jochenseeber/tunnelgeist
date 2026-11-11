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
  [Changing a device](#changing-a-device). The daemon closes any descriptor
  that comes with another request.

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
device: a process that holds a device's descriptor and key may only add what
its own configurations allow.

## Changing a device

`add_address`, `remove_address`, `add_route` and `remove_route` change a device
the daemon created. Each request line is sent in one `sendmsg` that carries the
device's open descriptor as `SCM_RIGHTS` ancillary data, exactly one, the way
the `create` reply carries it to the client. The client keeps its own copy.

The daemon takes the interface name of the descriptor from the kernel
(`getsockopt` with `SYSPROTO_CONTROL` and `UTUN_OPT_IFNAME`) and refuses the
request before it looks up the device when the request carries no descriptor,
more than one, one that is not a utun device, or the descriptor of another
device than the request's `name`:

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

## Operations

### create

Opens a utun device, brings it up, adds the addresses and routes and replies
with its name and key. `name` is `"utunN"` or `null` to let the kernel pick the
first free one; `mtu` is 1280 to 65535; `addresses` and `routes` may be empty.
An address is `{"address": "10.77.0.2", "prefix": 24, "peer": "10.77.0.1"}`
(IPv4, with a peer) or `{"address": "fd77::2", "prefix": 64}` (IPv6, without
one). A route is a prefix such as `"10.99.0.0/16"`.

Request:

<!-- dprint-ignore -->
```json
{"version":1,"op":"create","name":null,"mtu":1400,"addresses":[{"address":"10.77.0.2","prefix":24,"peer":"10.77.0.1"},{"address":"fd77::2","prefix":64}],"routes":["10.99.0.0/16","fd99::/48"]}
```

Reply:

<!-- dprint-ignore -->
```json
{"ok":true,"name":"utun7","key":"Kq3vZ8xY1wT5uR7oP2nM4lK6jH9gF0dS_aB-cDeFgHi"}
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
{"version":1,"op":"add_address","name":"utun7","key":"Kq3vZ8xY1wT5uR7oP2nM4lK6jH9gF0dS_aB-cDeFgHi","address":{"address":"fd77::2","prefix":64}}
```

Reply:

<!-- dprint-ignore -->
```json
{"ok":true}
```

`remove_address`:

<!-- dprint-ignore -->
```json
{"version":1,"op":"remove_address","name":"utun7","key":"Kq3vZ8xY1wT5uR7oP2nM4lK6jH9gF0dS_aB-cDeFgHi","address":{"address":"fd77::2","prefix":64}}
```

`remove_address` accepts only an address the daemon added for that device.
Adding an address the device already has is an error.

### add_route and remove_route

Request:

<!-- dprint-ignore -->
```json
{"version":1,"op":"add_route","name":"utun7","key":"Kq3vZ8xY1wT5uR7oP2nM4lK6jH9gF0dS_aB-cDeFgHi","route":"10.99.0.0/16"}
```

Reply:

<!-- dprint-ignore -->
```json
{"ok":true}
```

`remove_route`:

<!-- dprint-ignore -->
```json
{"version":1,"op":"remove_route","name":"utun7","key":"Kq3vZ8xY1wT5uR7oP2nM4lK6jH9gF0dS_aB-cDeFgHi","route":"10.99.0.0/16"}
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
- `key` is 43 characters of `A-Za-z0-9_-`. Any other text gets the error
  `invalid key: not 43 characters of A-Za-z0-9_-`, which never quotes the text.
- `mtu` is an integer from 1280 to 65535.
- Addresses and routes are IPv4 or IPv6 literals without a zone (`%`). A route
  is `ADDRESS/LENGTH` with a length that has no leading zero and no host bits
  set: `10.99.0.0/16` is valid, `10.99.0.1/16` is not.
- The prefix length of an address is 0 to 32 (IPv4) or 0 to 128 (IPv6). An IPv4
  address has a `peer` of the same family; an IPv6 address has none.
- A `create` has at most 16 addresses and 64 routes, and a device has at most
  that many in total, counting what it already has.
- Every field has its type: a string where a string is expected, an integer
  where an integer is expected. Nothing but the fields listed is accepted.

A failed `ifconfig` or `route` turns into an error reply that carries the
program, its exit status and its standard error. A client error never stops the
daemon.

## Identical errors

An unknown device name, a name the daemon did not create and a wrong key of the
right form all get the same reply, so the reply does not reveal which
interfaces exist:

<!-- dprint-ignore -->
```json
{"ok":false,"error":"unknown device or wrong key"}
```

## Keys

The key is 32 random bytes from the system's secure generator, encoded as
unpadded base64url: 43 characters. A change needs it and the device's
descriptor: any process the daemon admits that holds both may change that
device, within what its own client configurations allow, which lets a client
pass both to another process. The daemon compares keys in constant time and
never writes one to its log; a client should not either.
