# Contributing to tunnelgeist

How to build, test and change tunnelgeist. It runs on macOS only; every source
file is skipped on other systems.

## Rake tasks

Everything in development goes through `rake`:

| Task                                         | What it does                                                                                                                                                                                                                           |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `setup`                                      | Sets up the project: installs the shards (`deps`).                                                                                                                                                                                     |
| `deps`                                       | Installs the Crystal dependencies into `lib/`.                                                                                                                                                                                         |
| `spec[pattern]`                              | Runs the unit tests in `spec/` (microtest), which use nothing outside the project but a temporary directory; see [Testing](#testing). `pattern` is passed on as `--example`, which microtest does not read yet, so it narrows nothing. |
| `spec:focus[paths]`                          | Runs only the spec paths given.                                                                                                                                                                                                        |
| `tunnelgeist:spec[pattern]`                  | The same as `spec`, for the one component.                                                                                                                                                                                             |
| `cover`, `tunnelgeist:cover`                 | Runs the unit tests with coverage into `coverage/`.                                                                                                                                                                                    |
| `test[pattern]`, `tunnelgeist:test[pattern]` | Runs the integration tests in `test/tunnelgeist/` (microtest), which use the system; not the daemon tests. `pattern` as for `spec`.                                                                                                    |
| `exercise`                                   | Runs the daemon tests in `test/daemon/` with real utun devices; see [Testing](#testing). Builds the daemon, asks for your `sudo` password once, starts it as root and runs the tests as you.                                           |
| `docs`                                       | Builds the API docs into `.tmp/docs/` with `crystal docs`; the README is their index page.                                                                                                                                             |
| `format[check]`                              | Formats the Crystal sources in `src/`, `spec/` and `test/`; with `check`, only reports files that would change.                                                                                                                        |
| `lint`, `lint:crystal`, `lint:spelling`      | Runs ameba over the Crystal sources and cspell over the tracked files.                                                                                                                                                                 |
| `build`, `build:debug`, `build:release`      | Builds the `tunnelgeist` program for every build profile of the host, in both or one mode. `build:<mode>:<profile>` builds one profile.                                                                                                |
| `debug`                                      | Builds the preferred debug profile.                                                                                                                                                                                                    |
| `tunnelgeist:run`                            | Runs the `tunnelgeist` program in debug mode.                                                                                                                                                                                          |
| `profiles`                                   | Lists the build profiles the host supports, per mode.                                                                                                                                                                                  |
| `prepare`                                    | Prepares the compile prerequisites; the other build tasks depend on it.                                                                                                                                                                |
| `clean`, `clobber`                           | Removes temporary products, or every generated file.                                                                                                                                                                                   |
| `dist:package`                               | Packages every built release profile into `dist/`.                                                                                                                                                                                     |
| `release[yes]`                               | Cuts a release: the release branch from `main`, the tag and the bumped development versions.                                                                                                                                           |
| `homebrew:formula:update`                    | Updates the Homebrew formula from the release binaries under `dist/`.                                                                                                                                                                  |
| `homebrew:tap`                               | Copies the formula into the local checkout of the tap and commits it there; never pushes.                                                                                                                                              |
| `notary:setup`                               | Stores the notarytool keychain profile for macOS code signing.                                                                                                                                                                         |

## Testing

The tests are written with microtest and come in three sets:

- The unit tests in `spec/`, run by `rake spec`, depend on nothing outside the
  project directory: not on the system's users and groups, not on whether they
  run as root, not on Security reading a real process, not on environment
  variables, external programs, the network, or files and directories the
  system has. Where the code takes its collaborators from the caller, the specs
  pass fakes: a `Membership` that names its members
  (`support/fake_membership.cr`), a `Peer` built by hand
  (`support/fake_peer.cr`), the user, group and signature lookups of
  `Config::Loader` and the directories it reads through
  (`support/fake_directory.cr`), and the runners, paths and owner of `Install`.
  Files and sockets a spec creates go into a fresh directory below the real
  path of `$TMPDIR`, which `support/temporary_directory.cr` makes and removes.
  That directory is the one thing a unit test takes from the system; `$TMPDIR`
  must be short enough for a socket path in it (under 104 bytes), and the
  helper says so when it is not. The fake directories of the loader apply the
  configuration's ownership and mode rules to the directories and files below
  the temporary directory only, so the directories above it do not matter.
- The integration tests in `test/tunnelgeist/`, run by `rake test`, are the
  tests that need the system: the directory service (`staff`, `wheel`,
  `nogroup`), Security on the test binary, `plutil`, `git`, the programs
  `CommandRunner` runs, the kernel event socket, the peer address of a
  descriptor that is no utun device, a kernel control socket of another control
  included, the default configuration path, the root-ness of the process, ACLs,
  the configuration loader, which checks every directory from `/` down to a
  file it reads, and `install` as root, which checks every directory above the
  ones it writes in up to `/`. Both need a `$TMPDIR` whose ancestors only root
  or you own and no one else may write, with no ACL that lets anyone else
  write. macOS's own per-user `$TMPDIR` below `/private/var/folders` is one; a
  `TMPDIR` below `/private/tmp`, which everyone may write, is not. They mirror
  the layout of `spec/`; `test/test_helper.cr` sets up microtest and
  `test/tunnelgeist/support/` holds their helpers. They run as you and change
  nothing on the system.
- The daemon tests in `test/daemon/`, run by `rake exercise` and by nothing
  else. A `Tunnelgeist::Client` asks a real daemon for utun devices, and the
  tests read the ICMP echo request of `ping -c1 -t2 10.77.3.2` from
  `device.fd`, check the routes the daemon adds and removes, and check that
  closing the device removes it, that a new device of a closed one's name is
  changed with its own descriptor, that a change sent as the client closes the
  device's last descriptor lands on that device and not on the next device of
  its name, that the daemon refuses a change sent with another device's
  descriptor and a second address with the same local address, that it refuses
  an address and a route its configuration does not allow (`10.99.0.1/24`,
  `10.99.0.0/16`) without creating a device, and that it keeps at most 16
  devices of one user. Each test waits for the interfaces of its devices to go
  before the next one starts. They need macOS and root for the daemon only; the
  tests themselves run as you, as any client does, and find the daemon's socket
  in `TUNNELGEIST_SOCKET`. `rake exercise` builds the daemon and the tests,
  runs `sudo -v` (the one password prompt) and writes the daemon's
  configuration with `sudo` to
  `/private/var/root/tunnelgeist-daemon-test-HASH/config.json`, in root's home,
  where `HASH` is the first 8 hex digits of the SHA-256 of the checkout's real
  path, so that two checkouts do not share it. The daemon reads its
  configuration only through directories root owns, and your home directory is
  yours. The configuration names the socket `.work/tunnelgeist.sock`, your
  primary group, and one client, `daemon-test`, that allows addresses in
  `10.77.0.0/16` with peers there and routes to `10.78.0.0/16` and
  `10.79.0.0/16`, and nothing else. The task starts the daemon with
  `sudo -n .work/tunnelgeist serve --config PATH`, its standard input the null
  device and its standard output and error going to
  `$TMPDIR/tunnelgeist-exercise-HASH-TIME.log`, whose path it prints and keeps,
  runs the tests as you with `TUNNELGEIST_SOCKET` set, then stops the daemon
  and removes the configuration and its directory with `sudo`, also when a step
  failed, and warns when it cannot. A new daemon test that needs another prefix
  widens that configuration in `rakelib/tunnelgeist.rake`.

A test that needs anything outside the project is an integration test, even
when only one assertion of it does. Code is not given a test seam to keep a
test in `spec/`.

```sh
rake spec
rake test
rake exercise   # starts the daemon under sudo
```

## Commits

- Commit one concern per commit.
- Commit subjects follow Conventional Commits (`feat: ...`, `fix: ...`,
  `docs: ...`, `build: ...`).

## Gates before committing

GitHub Actions (`.github/workflows/ci.yml`) runs the format check, `rake lint`,
`rake docs`, `rake spec` and `rake test` on a macOS runner for every branch
push and pull request; the daemon tests below run only locally. Every Monday,
`.github/workflows/scheduled.yml` runs `rake spec` and `rake test` against the
latest Crystal release, so a new compiler that breaks tunnelgeist shows up
without a push; run it by hand from the Actions tab to check now.

```sh
rake spec
rake test
rake 'format[check]'
rake lint
```

Also build the daemon with `rake build:debug`, and run `rake exercise` after a
change to the device, the daemon or the client. `rake lint` also type-checks
the example programs in `examples/` against the library and spell-checks every
tracked file; add real terms to `cspell.dict`, never misspellings.
Documentation is formatted with `dprint fmt`.

`docs/protocol.md` has `<!-- dprint-ignore -->` before each of its `json` code
blocks. The examples are the exact lines the library writes, and
`spec/tunnelgeist/protocol_examples_spec.cr` parses each request example and
checks that it encodes back to the same line. dprint would reformat the JSON
and break that check. Keep the marker when adding an example.

## Source layout

`src/tunnelgeist.cr` is the entry point of the library; it requires the library
files only. `src/bin/tunnelgeist.cr` is the program, the target in `shard.yml`,
and holds nothing but one `require` a macro picks by platform:
`src/bin/tunnelgeist_macos.cr` on macOS, the composition root of the daemon,
which runs `Tunnelgeist::CLI` with the real streams and `SUDO_USER`, and
`src/bin/tunnelgeist_other.cr` elsewhere, which prints
`tunnelgeist: macOS only` and exits 1. Platform code is chosen this way, by
whole files, never by a conditional inside a component.

A nested type lives in the directory of its namespace, one type per file:
`Protocol::Create` in `protocol/create.cr`, `Client::Device` in
`client/device.cr`. A file requires the file of its superclass; a parent file
requires its nested types, except a nested type that subclasses the parent.

A nested file also requires every file whose constants or methods it uses, the
parent's included, so that it works as the only file a program requires.
Constants and helpers that several nested types share live in a file of their
own, such as `protocol/common.cr`, and not in the parent's file. When requiring
the parent at the top would load a subclass of the nested type before the type
exists, the nested file requires the parent at its end. `client/device.cr`,
whose `Client::Device` calls `Client#exchange`, requires `client.cr` at its
top. A superclass that names its subclasses only inside method bodies, as
`Protocol::Request.parse` does, does not require them; their files require it.

The lists below name the files of the top-level types, which bring their nested
types along.

The C bindings are `lib`s in the namespace of the code that uses them, one per
file and named for what they bind, such as `Device::LibUtun` in
`device/lib_utun.cr`. They write the standard library's C types as
`::LibC::Int`, and no binding is called `LibC`. A declaration two bindings need
is made once, in the lower-level one: `DepartureWatcher::LibKernelEvent` takes
`PF_SYSTEM`, the interface name size and `ioctl` from `Device::LibUtun`.

The library, which a program that depends on the shard gets with
`require "tunnelgeist"`:

- `address`, `prefix`: the `Address` record and the strict `Prefix` parser.
- `interface_name`: the `InterfaceName` value type, checked where it is parsed.
- `commands`: the `ifconfig` and `route` argument vectors.
- `device` (with its bindings in `device/lib_utun`): opens a utun device as
  root, and reads the interface name of a utun descriptor.
- `fd_passing` (bindings in `fd_passing/lib_socket`): sends and receives a
  descriptor over a Unix socket.
- `protocol`: the requests and replies, with their validation. They are read
  and written with `JSON::Serializable`; every field has one of the converters
  in `protocol/` (`text_converter`, `integer_converter`, `boolean_converter`,
  `list_converter`, `address_converter`), which raise a `Protocol::Error`
  naming the field, and `protocol/strict_fields` refuses an unknown field the
  same way. `protocol/syntax_check` checks the whole line first, the syntax and
  that no object holds a key twice, and `protocol/document` holds the address
  object and the fields read before a whole message. These are the reader's
  internals and marked `:nodoc:`. An annotation names its converter in full,
  from `Tunnelgeist::`: `JSON::Serializable#to_json` looks it up from its own
  namespace.
- `client`: `Tunnelgeist::Client`, with `Device` and `Error`.
- `version`.

The daemon: `src/bin/tunnelgeist_macos.cr` requires `cli`, which requires what
the daemon needs, and no library file requires any of these:

- `cli`, `install`, `launchd` (with its bindings in `launchd/lib_launch`): the
  command line, `install` and `uninstall`, and the launchd socket.
  `cli/options` reads each command's options, the `cli/flag` values it takes,
  and `cli/listener` holds the socket `serve` listens on with its path, which
  `cli/socket_path` reads back from a socket launchd passed. `install/paths`
  says where `install` writes, `install/writer` checks those directories and
  creates and writes there through `trusted_directory`, and `install/starter`
  builds the starter configuration it writes when there is none.
- `server`, `handler`, `registry`, `departure_watcher` (with its bindings in
  `departure_watcher/lib_kernel_event`), `command_runner` (with its bindings in
  `command_runner/lib_spawn`): the accept loop, the request handler, the
  registry of the devices, and the watcher that drops a device when its
  interface goes away. `registry/entry` is one device with its owner,
  `registry/reservation` a device slot taken for a user before the device
  exists, which the device limits count, and `registry/rejection` a change the
  registry refused. `handler/admitted` pairs an admitted peer with its
  admission, which judges the items of its request, and `handler/request_line`
  reads the request line with the descriptors that came with it and pins the
  device a change names with its descriptor.
- `peer`, `membership`, `signature_policy`, `config`, `authorizer`,
  `entitlement`, `refusal`, and their bindings `lib_system`, `lib_bsm`,
  `lib_cf` and `lib_security`: the peer checks. `config` is the parsed
  configuration: `config/loader` reads and validates the main file and its
  includes, `config/document` holds the `JSON::Serializable` types of the
  files' shape that the loader reads them into, `config/syntax_check` checks a
  file's JSON syntax and refuses a key given twice before that,
  `config/field_path` builds the field paths errors name, `config/location` is
  the line and column of an error the JSON reader found, `config/client` and
  `config/address_rule` are one client configuration and one of its address
  rules, `config/error` names the file and field of a refused configuration,
  and `config/holder` keeps the configuration in use and swaps it on `SIGHUP`.
  `authorizer` applies the group membership and the client configurations, with
  their signature policies, to a peer: `authorizer/admission` holds the
  configurations that apply and judges the addresses and routes of a request,
  `authorizer/client_refusal` says why one configuration did not apply, and
  `authorizer/denial` is a refused item with the text of its error reply. Only
  `lib_bsm`, `lib_cf` and `lib_security` link the BSM library, CoreFoundation
  and Security, so only the daemon does; a program that uses the client or
  `Device` links none of them.
- `checked_directory`, `trusted_directory`, `trust_policy`: the directories the
  daemon trusts. `checked_directory` is a checked directory, which the
  configuration loader reads each file through and `install` writes each file
  through (with `checked_directory/refusal`, its error naming the path it
  refused and why, and `checked_directory/missing`, the one for a name that
  does not exist), and `trusted_directory` the one the daemon uses, which opens
  each directory and file through checked descriptors from `/` down (with its
  bindings in `lib_directory` and `lib_acl`). `trust_policy` decides what
  passes from a `file_status` and the `acl_entry`s with their
  `acl_permissions`, and `trusted_file` is the text read with its path.

`family` belongs to the library: `address`, `prefix` and `commands` require it.
So does `decimal`, the check of ASCII digits that `interface_name`, `prefix`,
`membership` and `config/loader` share.

The daemon's limits are constants next to what they bound:
`Server::MAX_CONNECTIONS`, `Handler::MAX_CONNECTIONS_PER_USER`,
`Registry::MAX_DEVICES` and `Registry::MAX_DEVICES_PER_USER`,
`CommandRunner::COMMAND_TIMEOUT`, `COMMAND_OUTPUT_LIMIT` and
`COMMAND_CONCURRENCY`, `TrustPolicy::MAX_FILE_SIZE`, and in
`protocol/common.cr` `MAX_REQUEST`, `REQUEST_TIMEOUT`, `MAX_ADDRESSES` and
`MAX_ROUTES`. The server, the handler and the registry take their limits, and
`CommandRunner.run` its time and output limit, as arguments that default to
these, so a spec reaches a limit with a few devices or a short time; the daemon
passes none. `docs/protocol.md`, `docs/client.md` and `docs/configuration.md`
state the values, so a changed limit changes them too.

Nothing in `src/` uses a `Regex`: one regex links PCRE2 into the daemon, about
490 KB of the static release binary, and the static profile does not link it.
Check text with `Char` and `String` methods instead, and parse the command line
with `cli/options`, not `OptionParser`, which uses regexes inside. A regex that
creeps back in links PCRE2's `.dylib` into the static build, which `rake build`
refuses.

`spec/spec_helper.cr` sets up microtest and runs the suite; every spec requires
it. `spec/tunnelgeist/` has the specs of the source files, `client_spec.cr`
against the real handler, `protocol_examples_spec.cr` for `docs/protocol.md`
and `examples_spec.cr` for the configuration in `examples/config`;
`spec/tunnelgeist/support/` holds their helpers: `client_configs.cr` builds
client configurations and admissions by hand for the specs of the authorizer,
the handler, the server, the client and the configuration holder,
`fake_membership.cr` and `fake_peer.cr` stand in for the group and the peer,
`descriptor_sender.cr` sends several descriptors in one message,
`registrations.cr` registers devices with a reservation, `server_runs.cr` runs
a server in a fiber and asks it as a client, `temporary_directory.cr` makes the
temporary directories, and `fake_directory.cr` stands in for the checked
directories the configuration loader reads through and raises the error of
`outside_temporary_directory.cr` when a spec asks it for one outside the
temporary directory. A spec reads fixtures from the project itself, such as
`examples/config` and `docs/protocol.md`, and writes only below its temporary
directory.

`test/test_helper.cr` does the same for the integration tests in
`test/tunnelgeist/`, named `*_test.cr` after the spec of the same source file;
`test/tunnelgeist/support/` holds their helpers: `own_peer.cr` reads this
process as a peer, `temporary_directory.cr` is the suite's own copy of the
temporary directories, and `trusted_temporary_directory.cr` checks that the
configuration loader accepts the directories down to one and says which
directory fails when it does not, and `raw_acl.cr` sets an ACL with rights
`chmod +a` cannot set, through the `fchmod_extended` system call that
`lib_kauth.cr` binds. They may also use the spec helpers `client_configs.cr`,
`registrations.cr` and `server_runs.cr`. `test/daemon/device_test.cr` holds the
daemon tests.

## Releasing

The Homebrew formula lives in `deploy/homebrew/tunnelgeist.rb` and is published
in the tap `jochenseeber/homebrew-tap`. Its archive URLs point at the GitHub
releases of `jochenseeber/tunnelgeist`, tagged `vVERSION`.

The formula in the project is a template: its version is `0.0.0` and its
checksums are zeros, and it is never committed with real values.
`rake homebrew:formula:update` fills them in the working tree from the archive
under `dist/`, and only the tap holds the filled formula.

### With GitHub Actions

1. On `main`, or on a release branch for a patch release, `rake release[yes]`
   commits the release version, tags it `vVERSION`, commits the next
   development version after the tag and returns to the branch it started on.
   It pushes nothing.
2. Push the branches and the tag as `rake release` printed. The tag starts
   `.github/workflows/release.yml`: it checks that the tag matches `shard.yml`,
   runs CI (`.github/workflows/ci.yml`), then on a macOS runner runs
   `rake build:release` (build, sign, notarize), `rake dist:package` and
   `rake homebrew:formula:update`, publishes the GitHub release with the
   archive, and pushes the filled formula to the tap. For a version without a
   suffix it then deploys the API docs to GitHub Pages
   (`.github/workflows/docs.yml`), at
   <https://jochenseeber.github.io/tunnelgeist/>; a prerelease leaves the last
   release's docs in place.

The workflow needs these repository secrets: `MACOS_CERTIFICATE_P12_BASE64`,
`MACOS_CERTIFICATE_PASSWORD`, `MACOS_KEYCHAIN_PASSWORD`, `MACOS_SIGN_IDENTITY`,
`MACOS_NOTARY_API_KEY_P8_BASE64`, `MACOS_NOTARY_KEY_ID`,
`MACOS_NOTARY_ISSUER_ID` and `HOMEBREW_TAP_DEPLOY_KEY`; the head of
`release.yml` says what each holds. It imports the certificate into a temporary
keychain and stores a notarytool keychain profile there from the App Store
Connect API key, so `rake` signs and notarizes exactly as on a developer's
machine.

Publishing the docs needs two repository settings, made once in the GitHub web
interface: under Settings → Pages, the source "GitHub Actions"; and under
Settings → Environments → `github-pages`, a deployment rule that allows only
`main` and tags `v*`. To publish the docs of `main` in between, such as before
the first release, run the Docs workflow by hand from the Actions tab.

### By hand

A release built locally needs a Developer ID signing identity
(`CODESIGN_IDENTITY`, or the 1Password item `rake build:release` names when it
is missing) and the notarytool keychain profile from `rake notary:setup`.

1. `rake release[yes]` as above.
2. Check out the tag, `git checkout vVERSION` (a detached HEAD), so the build
   and `shard.yml` carry the release version. `rake build:release` builds,
   signs and notarizes the program, and `rake dist:package` writes
   `dist/tunnelgeist-darwin-arm64-system-static.tar.gz`.
3. Still on the tag, `rake homebrew:formula:update` sets the formula's version
   from `shard.yml` and its checksum from that archive. It refuses a `-dev`
   version, which is why it runs on the tag and not on a branch.
4. Push the branches and the tag as `rake release` printed (which starts the
   release workflow too, if the repository has it enabled), or create the
   GitHub release for the tag yourself with the archive attached, e.g.
   `gh release create vVERSION dist/tunnelgeist-*.tar.gz`.
5. `rake homebrew:tap` copies the formula into the tap checkout
   (`brew --repository jochenseeber/tap`, or `HOMEBREW_TAP_DIR`) and commits it
   there, refusing one that still has zero checksums; push the tap to publish
   it.
6. Put the template back and return to the branch:
   `git checkout -- deploy/homebrew/tunnelgeist.rb`, then `git checkout main`.
   `rake clean` removes the archive from `dist/`, which `rake release` would
   otherwise count as an unclean working tree next time.

The formula installs only the program; `sudo tunnelgeist install` sets up the
daemon from it, and the formula has no `service` block, since a brew service
would run the program in the user-owned Homebrew prefix as root. Only Apple
Silicon builds exist; an Intel build needs its own profile in `.project.yaml`
and an `on_intel` block in the formula.
