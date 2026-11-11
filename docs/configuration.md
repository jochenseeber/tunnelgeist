# Configuration

The daemon reads whom it serves, and what each client may do, from a JSON
configuration: a main file, `/usr/local/etc/tunnelgeist/config.json` unless
`serve --config PATH` names another, and the files it includes. `install`
([INSTALL.md](../INSTALL.md)) writes this starter file when there is none:

<!-- dprint-ignore -->
```json
{
  "socket": "/var/run/tunnelgeist.sock",
  "group": "tunnelgeist",
  "includes": [
    "clients.d/*.json"
  ],
  "clients": [
    {
      "name": "default",
      "addresses": [
        {
          "network": "10.0.0.0/8",
          "peer": "10.0.0.0/8"
        },
        {
          "network": "172.16.0.0/12",
          "peer": "172.16.0.0/12"
        },
        {
          "network": "192.168.0.0/16",
          "peer": "192.168.0.0/16"
        },
        {
          "network": "fc00::/7"
        }
      ],
      "routes": [
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "fc00::/7"
      ]
    }
  ]
}
```

It lets every member of the group `tunnelgeist` give a device addresses in the
private IPv4 ranges and the IPv6 unique local range, and route those ranges to
it. Add a program's own configuration as one file in `clients.d`, or edit the
main file. [examples/config](../examples/config) is a complete configuration
with a main file and two included client configurations.

## The main file

The main file is an object with these fields; any other field is an error, and
so is a field given twice in any object of any configuration file.

- `socket` (required): the absolute path of the Unix socket, at most 103 bytes
  long. `install` writes it into the plist, and `serve` binds it when launchd
  did not start the daemon.
- `group` (required): the main group, by name or by gid written as a string,
  such as `"20"`; messages and logs name it by its name. The socket is owned by
  root and this group with mode 0660, so only members can connect, and the
  daemon checks membership again for every connection before it looks at any
  client configuration. Every client must be a member.
- `includes` (optional): paths of files that each hold one client
  configuration, see [Includes](#includes).
- `clients` (optional): client configurations. The main file and the included
  files together must hold at least one.

## Client configurations

A client configuration says whom it applies to and what it allows. Its fields,
any other one being an error:

- `name` (required): a letter or digit followed by letters, digits, `.`, `_` or
  `-`, unique across all files. The daemon's log names configurations by it.
- `users` (optional): JSON strings, each a user name or a numeric user id
  written as a string, such as `"501"`, matched against the effective uid of
  the connecting process. A name the system does not know is an error, and so
  is a number that is not a string.
- `groups` (optional): group names or gids written as strings, such as `"20"`;
  the process's user must be a member of one, with nested and supplementary
  groups counting. These restrict further on top of the main group, which is
  always checked and never listed here.
- `signatures` (optional): code requirements, see
  [Signed programs](#signed-programs).
- `addresses` (optional): address rules, objects with a `network` and, for
  IPv4, a `peer`, both prefixes in CIDR notation. Without it the configuration
  allows no address.
- `routes` (optional): route destinations, prefixes in CIDR notation without
  host bits. Without it the configuration allows no route.

A configuration applies to a process when it meets each of `users`, `groups`
and `signatures` that the configuration lists, by any one entry of each: the
kinds combine with AND, the entries of one kind with OR. A field that is left
out restricts nothing, so a configuration without any of the three applies to
every member of the main group. A field that is present with an empty list
admits nobody. A process that is in the main group but to which no
configuration applies is refused with
`not permitted: not in group GROUP or not allowed by a client configuration`,
and the daemon's log names why each configuration did not apply.

The configurations that apply to a process together decide what it may ask for;
each one adds to what the others allow. An address passes an address rule when
the network it describes, its address with its own prefix length, lies inside
`network`: under `10.77.0.0/16`, `10.77.3.1/24` passes, and `10.77.3.1/8` and
`10.78.0.1/24` do not. An IPv4 address also needs its peer inside the rule's
`peer`, so an IPv4 rule without `peer` passes nothing. An IPv6 rule takes no
`peer`, and a rule of the other address family never matches. A route passes
when its destination lies inside one of the `routes`: `10.77.1.0/24` and
`10.77.0.0/16` pass under `10.77.0.0/16`, `10.0.0.0/8` does not, and an IPv6
destination is refused when only IPv4 prefixes are listed. `0.0.0.0/0` and
`::/0` allow every address or route of their family.

An allowed address also gives the device the routes the kernel adds for it,
such as a host route to the peer of an IPv4 address and the route of the prefix
of an IPv6 address. `routes` does not judge these, so the address rules decide
them, and a wide `peer` is a wide grant: under
`{ "network": "10.8.0.0/24", "peer": "0.0.0.0/0" }` a client may draw the
traffic for any one IPv4 address to its device by making it the peer, even with
`"routes": []`.

`create` checks all of its addresses and routes before anything happens,
`add_address` and `add_route` check their item, and the remove operations are
not checked. The first item that fails is named in the error reply, such as
`address 10.99.0.1/24 not allowed` or `route 10.99.0.0/16 not allowed`. The
process making the request is judged, not the one that created the device, so a
process that holds another's device descriptor can only add what its own
configurations allow.

A configuration for one VPN client, kept in `clients.d/vpn.json`:

```json
{
    "name": "vpn",
    "users": ["vpn"],
    "addresses": [{ "network": "10.8.0.0/24", "peer": "10.8.0.0/24" }],
    "routes": ["10.20.0.0/16", "10.21.0.0/16"]
}
```

## Includes

Each entry of `includes` is a path or a glob, relative to the main file's
directory. Only the last path component may hold the glob characters `*`, `?`
and `[`; a glob's files are read in name order, a name starting with `.`
matches only a pattern that starts with `.`, and a glob that matches nothing,
or whose directory does not exist, is not an error. A path without glob
characters must exist. An absolute entry is opened from `/`. An entry or a main
path that ends in `/` names a directory, as it does for any program, and is
refused. An entry with a `..` component is refused, and so is a main path with
one: the daemon opens each file by going down from a checked directory, never
up (see [Ownership](#ownership)).

## Ownership

The daemon runs as root, so a configuration file another user could change or
replace would let that user widen what root does. It opens every file, the main
one and each included one, by going down from `/` one directory at a time, and
checks each directory it opens before it opens the next name in it:

- every directory from `/` down to the file must be a directory, not a symbolic
  link, owned by root or the user the daemon runs as, and writable by neither
  its group nor others;
- the file must be a regular file, not a symbolic link, owned by the user the
  daemon runs as (root under launchd), writable by neither its group nor
  others, and at most 1 MiB;
- no directory and not the file may have an ACL entry that allows anyone but
  its owner, a group included, more than reading: an entry may allow only
  `read` (`list` on a directory), `execute` (`search`), `readattr`,
  `readextattr`, `readsecurity` and `synchronize`. Anything else, such as
  `write`, `append`, `delete`, `add_file` or `chown`, or a generic right, which
  `ls -le` shows as an `allow` with no rights after it, is refused. An entry
  the object inherited counts like its own; entries that deny are fine.

The daemon reads the file from the descriptor it checked, so nothing swapped in
along the path between the check and the read is read. A refused directory is
named in the error, as in
`/usr/local/etc: directory must be writable only by its owner, not mode 0775`
or `/usr/local/etc/tunnelgeist/clients.d: grants write access through its ACL`.
`/etc` and `/var` are symbolic links to `/private/etc` and `/private/var`, so
name a configuration there by its `/private` path. A relative `--config` path
is taken from the physical working directory, as `pwd -P` prints it, whose
directories pass the same checks.

`ls -le` shows a file's ACL and `chmod -N` removes it. The `clients.d`
directory `install` creates is owned by root:wheel with mode 0755, so a
program's file goes there with `sudo`:

```sh
sudo install -o root -g wheel -m 0644 vpn.json /usr/local/etc/tunnelgeist/clients.d/
```

## Loading and reloading

`serve` loads the configuration before it listens. An error names the file and,
when there is one, the field, as in
`/usr/local/etc/tunnelgeist/clients.d/vpn.json: field routes[1]: route 10.21.0.1/16 has host bits set`.
An error in the JSON itself, or in its shape, such as an unknown field or a
value of the wrong type, also names the line and column, as in
`/usr/local/etc/tunnelgeist/config.json:3:3: field colour: unknown field "colour"`.
A configuration that does not load ends the daemon with exit code 1 and the
error on standard error. When launchd started the daemon it uses the socket
launchd passes and logs `listening socket=PATH source=launchd`; otherwise it
binds the configuration's socket itself, owned by root and the main group with
mode 0660, and logs `source=bound`; started by a user other than root it keeps
that user as the owner and logs so. It then logs
`serving group=GROUP clients=N config=PATH`.

`SIGHUP` loads the configuration again while the daemon runs:

```sh
sudo launchctl kill HUP system/io.github.jochenseeber.tunnelgeist
```

On success the log says `configuration reloaded clients=N`, and the next
connection is judged by the new configuration; a connection accepted before the
reload keeps what it was admitted with for its one request, and devices that
exist keep their addresses and routes. A configuration that does not load is
logged as `configuration reload failed: ...` and the old one stays in use. The
`socket` and the `group` need a reinstall: a changed one is logged as
`configuration socket changed to PATH, reinstall to apply` or
`configuration group changed to GROUP, reinstall to apply`, and the running
values stay. The plist launchd reads names both, so run
`sudo tunnelgeist install` again ([INSTALL.md](../INSTALL.md)). A daemon that
is not running has nothing to reload; launchd starts it on the next request,
and it reads the files then.

## Signed programs

To serve only programs with a given code signature, list one or more
requirements in the `signatures` field of a client configuration; a program
that meets any one of them satisfies the field.
[examples/config/clients.d/vpn.json](../examples/config/clients.d/vpn.json)
admits one Developer ID signed program this way.

```sh
codesign -d -r- /path/to/program
```

`codesign -d -r-` prints the designated requirement of a signed program as
`designated => REQUIREMENT`; drop the leading `designated =>` and put the rest
in `signatures`, or write one in Apple's
[code requirement language](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html)
([TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
explains how macOS evaluates them). A requirement that does not compile stops
the daemon from loading the configuration.

A program that meets a requirement is refused all the same unless it has a
valid signature and the hardened runtime, has not been debugged and is not
debuggable, and holds none of the entitlements
`com.apple.security.get-task-allow`,
`com.apple.security.cs.disable-library-validation`,
`com.apple.security.cs.allow-dyld-environment-variables` and
`com.apple.security.cs.allow-unsigned-executable-memory`. Otherwise another
process of the same user could inject code into a signed program, with
`DYLD_INSERT_LIBRARIES` or a debugger, and pass the check in its name. Sign
with `codesign --options runtime`. A program that is only signed ad-hoc, as
compilers leave what they build, carries no identity a requirement could name,
so it cannot be restricted this way.

## Refusals

A client sees only the reply: the refusal
`not permitted: not in group GROUP or not allowed by a client configuration`
when no configuration admits it, or `address ADDRESS not allowed` or
`route ROUTE not allowed` for an item no configuration allows. The daemon logs
the reason to `/var/log/tunnelgeist.log`.

It logs `refused check=connections` for a process whose user has the most
connections open that the daemon serves for one user (see the limits in
[the protocol](protocol.md#limits)), `refused check=group` for a process
outside the main group, and `refused check=config` followed by one
`NAME=REASON` pair per client configuration otherwise, where the reason is
`users`, `groups`, `requirement`, `debugged`, `debuggable`, `hardened runtime`,
`entitlements unreadable` or `entitlement NAME`. A reason of several words is
quoted, as in `refused check=config default=users vpn="hardened runtime"`. A
refused address or route is logged with `configs=` and the names of the
configurations that applied.
