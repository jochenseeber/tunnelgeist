# Installing tunnelgeist

tunnelgeist runs on macOS only. Homebrew has builds for Apple Silicon Macs;
building it yourself needs Crystal 1.22 or later.

## With Homebrew

Install the program from the tap, then install the daemon from it:

```sh
brew install jochenseeber/tap/tunnelgeist
sudo tunnelgeist install
```

The daemon runs as root, so it never runs the program Homebrew installed.
`/opt/homebrew` belongs to your user, and anyone running as your user could
replace that program and run code as root. `install` copies it to root-owned
`/usr/local/libexec/tunnelgeist` as described below, and launchd runs that
copy. After `brew upgrade tunnelgeist`, run `sudo tunnelgeist install` again to
copy the new program. `brew services` cannot manage the daemon for the same
reason: it would run the program in the Homebrew prefix as root.

## From source

`rake build:release` builds the `tunnelgeist` program. Install the daemon from
it once with `sudo`:

```sh
sudo tunnelgeist install
```

## What install does

`install` copies the program to `/usr/local/libexec/tunnelgeist`, creates the
group `tunnelgeist` if it does not exist, and writes the starter configuration
to `/usr/local/etc/tunnelgeist/config.json`, with an empty `clients.d`
directory beside it (see [Configuration](docs/configuration.md)). It then loads
that configuration with the daemon's own checks and writes
`/Library/LaunchDaemons/io.github.jochenseeber.tunnelgeist.plist`, which starts
`tunnelgeist serve --config /usr/local/etc/tunnelgeist/config.json`. Last, it
loads the plist, so launchd listens on the configuration's socket. The socket
is `/var/run/tunnelgeist.sock` in the starter file, owned by root and the
configuration's group with mode 0660.

launchd starts the daemon when the first request arrives, and the daemon exits
again after 30 idle seconds with no device open. It logs to
`/var/log/tunnelgeist.log`, including the reason for each refusal.

`install` never replaces a configuration. When the main file exists it prints
`kept PATH` and uses it, else it prints `wrote PATH`. A configuration that does
not load stops `install` with the error before the running daemon is touched.
Running `install` again replaces the program and the plist, and is how a
changed `socket` or `group` takes effect.

Two options change this:

- `--group GROUP` names the group `install` creates when it is missing and
  writes into a new starter file (default `tunnelgeist`). An existing
  configuration keeps its own `group`, which the plist and the printed
  `dseditgroup` hint then use; that group must exist.
- `--config PATH` names another main file (default
  `/usr/local/etc/tunnelgeist/config.json`). `install` makes a relative path
  absolute, since launchd starts the daemon in `/`.

## Directory checks

`install` stops with a message, before it creates or writes anything, when one
of the directories it writes in is a symbolic link, is not owned by root or can
be written by anyone else. These directories are `/usr/local`,
`/usr/local/libexec`, the configuration directory and `clients.d`, and for a
directory that does not exist yet the nearest one above it. Every directory
above those up to `/` must pass the same check, since another user could
otherwise replace the program or the configuration. `install` refuses a
`/usr/local` that a Homebrew installation gave to your user for that reason.
`/etc` is a symbolic link to `/private/etc`, so name a configuration there as
`--config /private/etc/tunnelgeist/config.json`.

## Group membership

Add each user who may create devices to the group:

```sh
sudo dseditgroup -o edit -a USER -t user tunnelgeist
```

Members of the group may connect to the socket, and the kernel reads a
process's groups when its session starts. The first request right after this
may fail with `not permitted`: the client's
`tunnelgeist refused the connection`, or the daemon's
`not permitted: not in group tunnelgeist or not allowed by a client configuration`.
Then log out and in, or open a new terminal window, and try again. This applies
to any session that started before the change and is still running, such as
tmux, an IDE's terminal or an ssh login: start a new one.

Which members may create devices, and with which addresses and routes, is set
in the configuration; see [docs/configuration.md](docs/configuration.md).

## Uninstalling

To remove the daemon, its plist and its program, and keep the group and the
configuration:

```sh
sudo tunnelgeist uninstall
```

`uninstall` prints `left /usr/local/etc/tunnelgeist` for the configuration
directory it leaves; remove it by hand when you no longer need it.
