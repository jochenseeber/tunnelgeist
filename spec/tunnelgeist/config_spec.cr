require "file_utils"
require "json"
require "socket"
require "../spec_helper"
require "../../src/tunnelgeist/config"
require "../../src/tunnelgeist/config/address_rule"
require "../../src/tunnelgeist/config/document/main"
require "../../src/tunnelgeist/config/error"
require "../../src/tunnelgeist/config/file_status"
require "../../src/tunnelgeist/config/loader"
require "../../src/tunnelgeist/config/location"
require "../../src/tunnelgeist/signature_policy"
require "./support/fake_directory"
require "./support/fake_membership"
require "./support/outside_temporary_directory"
require "./support/fake_peer"
require "./support/temporary_directory"

# The client configuration (CF1 to CF4) and its loader (CA1, CC1, CC2),
# against files in a temporary directory with stubbed user, group and
# signature lookups, the owner of that directory as the owner the loader
# expects, and peers built by hand. What needs the system's users and groups,
# Security or the root-ness of the process is an integration test.
describe TunnelgeistConfig do
  {% if flag?(:darwin) %}
    include TunnelgeistFakePeer

    alias Config = Tunnelgeist::Config

    # The user names the stubbed lookup knows.
    USERS = {"alice" => 501_u32}

    # The group every known group name resolves to in the stubbed lookup.
    STAFF = TunnelgeistFakeMembership.new("staff", gid: 20_u32, members: [PEER_UID]).as(Tunnelgeist::Membership)

    # The uid that owns *path*, which the loader is told to expect, so the
    # specs need not know which user runs them.
    def self.owner_of(path : String) : UInt32
      File.info(path).owner_id.to_u32
    end

    # A directory with mode 0755 in a fresh temporary directory, named *name*
    # when given, holding the main file `config.json` and whatever else a
    # test writes.
    class Fixture
      getter directory : String

      def initialize(name : String? = nil)
        @root = TunnelgeistTemporaryDirectory.create_temporary_directory
        @directory = name ? File.join(@root, name) : @root
        Dir.mkdir_p(@directory)
        File.chmod(@directory, 0o755)
      end

      # The uid that owns the directory.
      def owner : UInt32
        TunnelgeistConfigTest.owner_of(@directory)
      end

      # The main file.
      def main : String
        File.join(@directory, "config.json")
      end

      # Writes *content* to *name* below the directory with mode 0644,
      # creating its directories with mode 0755, and returns the path.
      def write(name : String, *, content : String) : String
        path = File.join(@directory, name)
        parent = File.dirname(path)
        Dir.mkdir_p(parent)
        File.chmod(parent, 0o755)
        File.write(path, content)
        File.chmod(path, 0o644)
        path
      end

      def remove : Nil
        FileUtils.rm_rf(@root)
      end
    end

    # The stubbed lookups of a loader and what they were asked.
    class Lookups
      # The group names `build_membership` was asked for.
      getter groups = [] of String
      # The requirement lists `build_policy` was asked for.
      getter requirements = [] of Array(String)

      # A loader of *path* with these lookups: `nosuch` is an unknown group,
      # `bad` a requirement that does not compile, and every known group is
      # really `STAFF`. Users come from *find_user*, by default `USERS`. The
      # files must be owned by *owner*, by default the owner of the
      # directory of *path*. Directories are opened by a
      # `TunnelgeistFakeDirectory`, with *statuses* in place of what the file
      # system says about the paths they name.
      def loader(path : String, *, owner : UInt32 = TunnelgeistConfigTest.owner_of(File.dirname(path)),
                 find_user : String -> UInt32? = ->(name : String) : UInt32? { USERS[name]? },
                 statuses : Hash(String, Config::FileStatus) = {} of String => Config::FileStatus) : Config::Loader
        Config::Loader.new(path: path, owner: owner,
          find_user: find_user,
          open_directory: TunnelgeistFakeDirectory.opener(statuses: statuses),
          build_membership: ->(name : String) do
            @groups << name
            raise ArgumentError.new("unknown group #{name}") if name == "nosuch"
            STAFF
          end,
          build_policy: ->(requirements : Array(String)) do
            @requirements << requirements
            raise ArgumentError.new(%(requirement "bad" does not compile (OSStatus -67052))) if requirements.includes?("bad")
            Tunnelgeist::SignaturePolicy.new([] of String)
          end)
      end
    end

    def with_fixture(&)
      fixture = Fixture.new
      begin
        yield fixture
      ensure
        fixture.remove
      end
    end

    # A main file with *clients* (the JSON of the array) and *extra* fields.
    def main_json(*, clients : String = %([{"name": "default"}]), extra : String = "") : String
      %({"socket": "/var/run/tg.sock", "group": "tg", "clients": #{clients}#{extra}})
    end

    # Loads the main file of *fixture* with fresh lookups.
    def load(fixture : Fixture, *, owner : UInt32 = fixture.owner) : Config
      Lookups.new.loader(fixture.main, owner: owner).load
    end

    # The error loading the main file of *fixture* raises.
    def load_error(fixture : Fixture, *, owner : UInt32 = fixture.owner) : Config::Error
      raised(Config::Error) { load(fixture, owner: owner) }
    end

    # The reason of the error loading a main file with the one inline client
    # *client* raises, asserting it is about *field* of the main file. A
    # *located* error, one the JSON reader found in the file's shape, names
    # its line and column; one the loader's checks found names none.
    def client_error(client : String, *, field : String, located : Bool = false) : String
      reason = ""
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json(clients: "[#{client}]"))
        error = load_error(fixture)
        assert(error.file == fixture.main)
        assert(error.field == field)
        location = error.location
        if located
          assert(location)
          assert(error.message == "#{fixture.main}:#{location.try(&.line)}:#{location.try(&.column)}: field #{field}: #{error.reason}")
        else
          assert(location.nil?)
          assert(error.message == "#{fixture.main}: field #{field}: #{error.reason}")
        end
        reason = error.reason
      end
      reason
    end

    def ip(text : String) : Socket::IPAddress
      Socket::IPAddress.new(text, 0)
    end

    def prefix(text : String) : Tunnelgeist::Prefix
      Tunnelgeist::Prefix.parse(text)
    end

    def v4(address : String, *, bits : Int32, peer : String) : Tunnelgeist::Address
      Tunnelgeist::Address.new(ip(address), prefix: bits, peer: ip(peer))
    end

    def v6(address : String, *, bits : Int32) : Tunnelgeist::Address
      Tunnelgeist::Address.new(ip(address), prefix: bits)
    end

    def client(*, users : Array(UInt32)? = nil, groups : Array(Tunnelgeist::Membership)? = nil,
               policy : Tunnelgeist::SignaturePolicy? = nil) : Config::Client
      Config::Client.new(name: "c", users: users, groups: groups, policy: policy,
        addresses: [] of Config::AddressRule, routes: [] of Tunnelgeist::Prefix)
    end

    alias Reason = Tunnelgeist::Refusal::Reason

    def refused(reason : Reason) : Tunnelgeist::Refusal
      Tunnelgeist::Refusal.new(reason: reason)
    end

    # Loading

    test "load reads the main file, its inline client and the clients its include glob matches, in order" do
      with_fixture do |fixture|
        fixture.write("config.json", content: <<-JSON)
          {
            "socket": "/var/run/tg.sock",
            "group": "tg",
            "includes": ["clients.d/*.json"],
            "clients": [
              {
                "name": "default",
                "users": ["alice", "1234"],
                "groups": ["admin", "wheel"],
                "signatures": ["anchor apple", "anchor apple generic"],
                "addresses": [
                  {"network": "10.0.0.0/8", "peer": "10.0.0.0/8"},
                  {"network": "fc00::/7"}
                ],
                "routes": ["10.0.0.0/8", "fc00::/7"]
              }
            ]
          }
          JSON
        fixture.write("clients.d/b.json", content: %({"name": "b"}))
        fixture.write("clients.d/a.json", content: %({"name": "a", "routes": ["10.77.0.0/16"]}))
        lookups = Lookups.new

        config = lookups.loader(fixture.main).load

        assert(config.socket == "/var/run/tg.sock")
        assert(config.group == "staff")
        assert(config.membership.same?(STAFF))
        assert(config.clients.map(&.name) == ["default", "a", "b"])
        assert(lookups.groups == ["tg", "admin", "wheel"])
        assert(lookups.requirements == [["anchor apple", "anchor apple generic"]])

        default = config.clients[0]
        assert(default.users! == [501_u32, 1234_u32])
        assert(default.groups!.size == 2)
        assert(default.policy!.empty?)
        assert(default.addresses == [Config::AddressRule.new(network: prefix("10.0.0.0/8"), peer: prefix("10.0.0.0/8")),
                                     Config::AddressRule.new(network: prefix("fc00::/7"), peer: nil)])
        assert(default.routes == [prefix("10.0.0.0/8"), prefix("fc00::/7")])

        a = config.clients[1]
        assert(a.users.nil?)
        assert(a.groups.nil?)
        assert(a.policy.nil?)
        assert(a.addresses.empty?)
        assert(a.routes == [prefix("10.77.0.0/16")])
      end
    end

    test "load reads an included path without glob characters relative to the main file" do
      with_fixture do |fixture|
        fixture.write("config.json", content: %({"socket": "/s", "group": "tg", "includes": ["more/one.json"]}))
        fixture.write("more/one.json", content: %({"name": "one"}))

        assert(load(fixture).clients.map(&.name) == ["one"])
      end
    end

    test "load treats ? and [ as glob characters" do
      with_fixture do |fixture|
        fixture.write("config.json", content: %({"socket": "/s", "group": "tg", "includes": ["q/?.json", "s/[x].json"]}))
        fixture.write("q/a.json", content: %({"name": "a"}))
        fixture.write("q/ab.json", content: %({"name": "ab"}))
        fixture.write("s/x.json", content: %({"name": "x"}))
        fixture.write("s/y.json", content: %({"name": "y"}))

        assert(load(fixture).clients.map(&.name) == ["a", "x"])
      end
    end

    test "load reads an include with ], { or a non-ASCII character as a plain path" do
      with_fixture do |fixture|
        fixture.write("config.json", content: %({"socket": "/s", "group": "tg", "includes": ["l/a]b.json", "l/{c}.json", "l/＊.json"]}))
        fixture.write("l/a]b.json", content: %({"name": "ab"}))
        fixture.write("l/{c}.json", content: %({"name": "c"}))
        fixture.write("l/＊.json", content: %({"name": "star"}))
        fixture.write("l/x.json", content: %({"name": "x"}))

        assert(load(fixture).clients.map(&.name) == ["ab", "c", "star"])
      end
    end

    test "load accepts an include glob that matches nothing" do
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json(extra: %(, "includes": ["clients.d/*.json"])))

        assert(load(fixture).clients.map(&.name) == ["default"])
      end
    end

    test "load keeps an empty users, groups or signatures list, which admits nobody" do
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json(clients: <<-JSON))
          [{"name": "u", "users": []}, {"name": "g", "groups": []}, {"name": "s", "signatures": []}]
          JSON
        lookups = Lookups.new

        users, groups, signatures = lookups.loader(fixture.main).load.clients

        assert(users.users! == [] of UInt32)
        assert(groups.groups!.empty?)
        assert(signatures.policy!.empty?)
        assert(lookups.requirements == [[] of String])
        assert(users.applies?(fake_peer, inspection: nil) == refused(Reason::Users))
        assert(groups.applies?(fake_peer, inspection: nil) == refused(Reason::Groups))
      end
    end

    test "load skips hidden files unless the glob names them" do
      with_fixture do |fixture|
        fixture.write("config.json", content: %({"socket": "/s", "group": "tg", "includes": ["c/*.json"]}))
        fixture.write("c/.hidden.json", content: %({"name": "hidden"}))
        fixture.write("c/shown.json", content: %({"name": "shown"}))
        assert(load(fixture).clients.map(&.name) == ["shown"])

        fixture.write("config.json", content: %({"socket": "/s", "group": "tg", "includes": ["c/.*.json"]}))
        assert(load(fixture).clients.map(&.name) == ["hidden"])
      end
    end

    test "load finds an include glob below a main directory whose name holds glob characters" do
      fixture = Fixture.new("tg-config-[x]*")
      begin
        fixture.write("config.json", content: %({"socket": "/s", "group": "tg", "includes": ["clients.d/*.json"]}))
        fixture.write("clients.d/a.json", content: %({"name": "a"}))

        assert(load(fixture).clients.map(&.name) == ["a"])
      ensure
        fixture.remove
      end
    end

    # Rejections of the main file

    test "load refuses an unknown field in the main file, naming its line and column" do
      with_fixture do |fixture|
        content = main_json(extra: %(, "colour": "red"))
        fixture.write("config.json", content: content)

        error = load_error(fixture)

        column = content.index!(%("colour")) + 1
        assert(error.file == fixture.main)
        assert(error.field! == "colour")
        assert(error.location! == Config::Location.new(line: 1, column: column))
        assert(error.message == "#{fixture.main}:1:#{column}: field colour: unknown field \"colour\"")
      end
    end

    test "load names the line of a field in a main file of several lines" do
      with_fixture do |fixture|
        fixture.write("config.json", content: <<-JSON)
          {
            "socket": "/s",
            "colour": "red",
            "group": "tg"
          }
          JSON

        assert(load_error(fixture).message == "#{fixture.main}:3:3: field colour: unknown field \"colour\"")
      end
    end

    test "load refuses a main file without socket or group" do
      with_fixture do |fixture|
        fixture.write("config.json", content: %({"group": "tg", "clients": [{"name": "c"}]}))
        error = load_error(fixture)
        assert(error.field == "socket")
        assert(error.reason == "missing field socket")
        assert(error.location! == Config::Location.new(line: 1, column: 1))

        fixture.write("config.json", content: %({"socket": "/s", "clients": [{"name": "c"}]}))
        error = load_error(fixture)
        assert(error.field == "group")
        assert(error.reason == "missing field group")
      end
    end

    test "load refuses a mistyped main field" do
      with_fixture do |fixture|
        fixture.write("config.json", content: %({"socket": 1, "group": "tg", "clients": [{"name": "c"}]}))
        error = load_error(fixture)
        assert(error.field == "socket")
        assert(error.reason == "must be a string")
        assert(error.location! == Config::Location.new(line: 1, column: 12))

        fixture.write("config.json", content: main_json(extra: %(, "includes": "x.json")))
        error = load_error(fixture)
        assert(error.field == "includes")
        assert(error.reason == "must be an array")

        fixture.write("config.json", content: main_json(extra: %(, "includes": ["a.json", 2])))
        error = load_error(fixture)
        assert(error.field == "includes[1]")
        assert(error.reason == "must be a string")
      end
    end

    test "load takes null for an optional field as left out" do
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json(clients: <<-JSON, extra: %(, "includes": null)))
          [{"name": "c", "users": null, "groups": null, "signatures": null, "addresses": [{"network": "10.0.0.0/8", "peer": null}], "routes": null}]
          JSON

        client = load(fixture).clients.first

        assert(client.users.nil?)
        assert(client.groups.nil?)
        assert(client.policy.nil?)
        assert(client.addresses == [Config::AddressRule.new(network: prefix("10.0.0.0/8"), peer: nil)])
        assert(client.routes.empty?)

        fixture.write("config.json", content: %({"socket": "/s", "group": "tg", "clients": null}))
        assert(load_error(fixture).reason == "no client configuration in the file or its includes")
      end
    end

    test "load refuses a socket that is empty, relative, holds a NUL byte or is too long for a Unix socket address" do
      with_fixture do |fixture|
        long = "/#{"s" * 104}"
        {"" => "socket must be an absolute path", "tg.sock" => "socket must be an absolute path",
         "/var/run/t\0g.sock" => "socket contains a NUL byte",
         long => "Path size exceeds the maximum size of 103 bytes"}.each do |socket, reason|
          fixture.write("config.json", content: %({"socket": #{socket.to_json}, "group": "tg", "clients": [{"name": "c"}]}))
          error = load_error(fixture)

          assert(error.field == "socket")
          assert(error.reason == reason)
        end

        fixture.write("config.json", content: %({"socket": "/#{"s" * 102}", "group": "tg", "clients": [{"name": "c"}]}))
        assert(load(fixture).socket.bytesize == 103)
      end
    end

    test "load refuses an unknown main group, naming the field" do
      with_fixture do |fixture|
        fixture.write("config.json", content: %({"socket": "/s", "group": "nosuch", "clients": [{"name": "c"}]}))

        assert(load_error(fixture).message == "#{fixture.main}: field group: unknown group nosuch")
      end
    end

    test "load refuses malformed JSON, naming its line and column but no field" do
      with_fixture do |fixture|
        fixture.write("config.json", content: %({"socket": "/s))
        error = load_error(fixture)
        assert(error.field.nil?)
        assert(error.message == "#{fixture.main}:1:15: malformed JSON: Unterminated string")

        # The reader looks one token ahead, so without the syntax check this
        # would be blamed on socket, the field before it.
        fixture.write("config.json", content: %({"socket": "/s" "group": "tg"}))
        error = load_error(fixture)
        assert(error.field.nil?)
        assert(error.reason.starts_with?("malformed JSON: "))
        assert(error.location)

        fixture.write("config.json", content: "#{main_json} x")
        error = load_error(fixture)
        assert(error.field.nil?)
        assert(error.reason.starts_with?("malformed JSON: "))

        fixture.write("config.json", content: "")
        assert(load_error(fixture).message == "#{fixture.main}:1:1: malformed JSON: Unexpected end of input")
      end
    end

    test "load refuses a main file that is not an object" do
      with_fixture do |fixture|
        fixture.write("config.json", content: %([]))
        error = load_error(fixture)

        assert(error.field.nil?)
        assert(error.reason == "must be an object")
        assert(error.location! == Config::Location.new(line: 1, column: 1))
      end
    end

    test "load places a main file or an include that is a scalar at the scalar" do
      at = ->(line : Int32, column : Int32) { Config::Location.new(line: line, column: column) }
      {"null" => at.call(1, 1), %("x") => at.call(1, 1), "1" => at.call(1, 1),
       "\n  null" => at.call(2, 3), %( "x") => at.call(1, 2), "\t1" => at.call(1, 2)}.each do |content, location|
        with_fixture do |fixture|
          fixture.write("config.json", content: content)
          assert(load_error(fixture).message == "#{fixture.main}:#{location}: must be an object")

          fixture.write("config.json", content: main_json(extra: %(, "includes": ["c.json"])))
          included = fixture.write("c.json", content: content)
          assert(load_error(fixture).message == "#{included}:#{location}: must be an object")
        end
      end
    end

    test "load quotes a field name that is not a plain word and escapes control characters in an error" do
      assert(client_error(%({"name": "c", "x\\ny\\u001b[31mz": 1}), field: %(clients[0]."x\\ny\\e[31mz"), located: true) ==
             %(unknown field "x\\ny\\e[31mz"))
      assert(client_error(%({"name": "c", "a b": 1, "a b": 2}), field: %(clients[0]."a b"), located: true) ==
             %(duplicate field "a b"))

      with_fixture do |fixture|
        fixture.write("config.json", content: %({"socket": "/s\n", "group": "tg"}))
        error = load_error(fixture)

        assert(error.reason == %(malformed JSON: Unexpected char '\\n'))
        assert(!error.message.to_s.includes?('\n'))
      end
    end

    test "load refuses a file that is not valid UTF-8" do
      [%([{"name": "c\xFF"}]), %([{"name": "c", "users": ["alice\xFF"]}])].each do |clients|
        with_fixture do |fixture|
          fixture.write("config.json", content: main_json(clients: clients))

          assert(load_error(fixture).message == "#{fixture.main}: not valid UTF-8")
        end
      end

      with_fixture do |fixture|
        fixture.write("config.json", content: main_json(extra: %(, "includes": ["c.json"])))
        included = fixture.write("c.json", content: %({"name": "c\xFF"}))

        assert(load_error(fixture).message == "#{included}: not valid UTF-8")
      end
    end

    test "load refuses a configuration without any client" do
      with_fixture do |fixture|
        fixture.write("config.json", content: %({"socket": "/s", "group": "tg", "includes": ["clients.d/*.json"]}))

        error = load_error(fixture)

        assert(error.file == fixture.main)
        assert(error.field.nil?)
        assert(error.message == "#{fixture.main}: no client configuration in the file or its includes")
        assert(raised(NilAssertionError) { error.field! })
      end
    end

    test "load refuses a listed include that does not exist" do
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json(extra: %(, "includes": ["clients.d/*.json", "missing.json"])))

        error = load_error(fixture)

        assert(error.file == fixture.main)
        assert(error.field == "includes[1]")
        assert(error.message == "#{fixture.main}: field includes[1]: file #{fixture.directory}/missing.json does not exist")
      end
    end

    test "load refuses glob characters outside the last component of an include" do
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json(extra: %(, "includes": ["c.json", "cli*/x.json"])))
        fixture.write("c.json", content: %({"name": "c"}))
        fixture.write("clients/x.json", content: %({"name": "x"}))

        error = load_error(fixture)

        assert(error.file == fixture.main)
        assert(error.message ==
               "#{fixture.main}: field includes[1]: glob characters are allowed only in the last path component")
      end
    end

    test "load refuses a .. component in an include, before it opens anything" do
      ["../c.json", "a/../c.json", "a/../*.json", "/a/../c.json", "a/.."].each do |entry|
        with_fixture do |fixture|
          fixture.write("config.json", content: main_json(extra: %(, "includes": ["#{entry}"])))
          fixture.write("c.json", content: %({"name": "c"}))

          error = load_error(fixture)

          assert(error.message == "#{fixture.main}: field includes[0]: must not contain a .. component")
        end
      end
    end

    test "load refuses a .. component in the main path" do
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json)
        path = File.join(fixture.directory, "..", File.basename(fixture.directory), "config.json")

        error = raised(Config::Error) { Lookups.new.loader(path, owner: fixture.owner).load }

        assert(error.message == "#{path}: must not contain a .. component")
      end
    end

    test "load refuses a main path that ends in / or /. as a directory, as the system does" do
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json)

        ["#{fixture.main}/", "#{fixture.main}/."].each do |path|
          error = raised(Config::Error) { Lookups.new.loader(path, owner: fixture.owner).load }

          assert(error.message == "#{fixture.main}: must be a directory")
        end
        ["#{fixture.directory}/", "#{fixture.directory}/."].each do |path|
          error = raised(Config::Error) { Lookups.new.loader(path, owner: fixture.owner).load }

          assert(error.message == "#{fixture.directory}: must be a regular file")
        end
      end
    end

    test "load refuses an include that ends in / or /. as a directory, as the system does" do
      # %s stands for the fixture's directory, %m for its main file, each at most once.
      {"c.json/"     => "%s/c.json: must be a directory",
       "c.json/."    => "%s/c.json: must be a directory",
       "/%s/c.json/" => "%s/c.json: must be a directory",
       "d/"          => "%m: field includes[0]: must name a file",
       "d/*.json/"   => "%m: field includes[0]: must name a file",
       "x/"          => "%m: field includes[0]: file %s/x does not exist"}.each do |entry, expected|
        with_fixture do |fixture|
          fixture.write("c.json", content: %({"name": "c"}))
          fixture.write("d/a.json", content: %({"name": "a"}))
          listed = entry.sub("/%s", fixture.directory)
          fixture.write("config.json", content: main_json(extra: %(, "includes": [#{listed.to_json}])))

          error = load_error(fixture)

          assert(error.message == expected.sub("%s", fixture.directory).sub("%m", fixture.main))
        end
      end
    end

    test "load does not turn a fake directory asked for a path outside the temporary directory into a refusal" do
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json(extra: %(, "includes": ["/tunnelgeist-outside.json"])))

        error = raised(TunnelgeistOutsideTemporaryDirectory) { load(fixture) }

        assert(error.message.to_s.ends_with?("and below, not /"))
      end
    end

    test "load refuses an include with a NUL byte" do
      ["a\\u0000b.json", "c\\u0000/*.json"].each do |entry|
        with_fixture do |fixture|
          fixture.write("config.json", content: main_json(extra: %(, "includes": ["#{entry}"])))

          error = load_error(fixture)

          assert(error.file == fixture.main)
          assert(error.message == "#{fixture.main}: field includes[0]: String contains null byte")
        end
      end
    end

    # Rejections of a client

    test "load refuses an unknown field in an inline client and in an included one" do
      assert(client_error(%({"name": "c", "colour": "red"}), field: "clients[0].colour", located: true) ==
             %(unknown field "colour"))

      with_fixture do |fixture|
        fixture.write("config.json", content: main_json(extra: %(, "includes": ["c.json"])))
        included = fixture.write("c.json", content: %({"name": "c", "colour": "red"}))

        error = load_error(fixture)

        assert(error.file == included)
        assert(error.field == "colour")
        assert(error.message == "#{included}:1:15: field colour: unknown field \"colour\"")
      end
    end

    test "load refuses a client without a name" do
      assert(client_error(%({"routes": []}), field: "clients[0].name", located: true) == "missing field name")
    end

    test "load refuses a client name that is not a letter or digit followed by letters, digits, dots, underscores and dashes" do
      ["", "-web", ".web", "_web", "web 1", "web=1", "web/1", "wéb", "web\n", "ｗeb", "٣", "web٣", "web+1"].each do |name|
        assert(client_error(%({"name": #{name.to_json}}), field: "clients[0].name") ==
               %(invalid client name #{name.inspect}: must be a letter or digit followed by letters, digits, ".", "_" or "-"))
      end

      with_fixture do |fixture|
        fixture.write("config.json", content: main_json(clients: %([{"name": "Web-1.a_b"}, {"name": "0"}])))

        assert(load(fixture).clients.map(&.name) == ["Web-1.a_b", "0"])
      end
    end

    test "load refuses a client that is not an object, inline and included" do
      assert(client_error(%("c"), field: "clients[0]", located: true) == "must be an object")

      with_fixture do |fixture|
        fixture.write("config.json", content: main_json(extra: %(, "includes": ["c.json"])))
        included = fixture.write("c.json", content: %([{"name": "c"}]))

        error = load_error(fixture)

        assert(error.file == included)
        assert(error.field.nil?)
        assert(error.reason == "must be an object")
        assert(error.location)
      end
    end

    test "load refuses a client name used twice across files" do
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json(extra: %(, "includes": ["c.json"])))
        included = fixture.write("c.json", content: %({"name": "default"}))

        error = load_error(fixture)

        assert(error.file == included)
        assert(error.field == "name")
        assert(error.message == %(#{included}: field name: duplicate client name "default", also in #{fixture.main}))
      end
    end

    test "load refuses a bad CIDR in an address rule's network or peer" do
      assert(client_error(%({"name": "c", "addresses": [{"network": "10.0.0/8", "peer": "10.0.0.0/8"}]}),
        field: "clients[0].addresses[0].network") == %(invalid prefix "10.0.0/8": invalid address))
      assert(client_error(%({"name": "c", "addresses": [{"network": "fc00::/7"}, {"network": "10.0.0.0/8", "peer": "10.0.0.0"}]}),
        field: "clients[0].addresses[1].peer") == %(invalid prefix "10.0.0.0": missing prefix length))
    end

    test "load refuses an unknown or missing field in an address rule" do
      assert(client_error(%({"name": "c", "addresses": [{"network": "fc00::/7"}, {"network": "10.0.0.0/8", "via": "x"}]}),
        field: "clients[0].addresses[1].via", located: true) == %(unknown field "via"))
      assert(client_error(%({"name": "c", "addresses": [{"peer": "10.0.0.0/8"}]}),
        field: "clients[0].addresses[0].network", located: true) == "missing field network")
      assert(client_error(%({"name": "c", "addresses": [{"network": "10.0.0.0/8", "peer": 8}]}),
        field: "clients[0].addresses[0].peer", located: true) == "must be a string or null")
    end

    test "load refuses a peer on an IPv6 rule and an IPv6 peer on an IPv4 rule" do
      assert(client_error(%({"name": "c", "addresses": [{"network": "fc00::/7", "peer": "fc00::/7"}]}),
        field: "clients[0].addresses[0].peer") == "an IPv6 rule takes no peer")
      assert(client_error(%({"name": "c", "addresses": [{"network": "10.0.0.0/8", "peer": "fc00::/7"}]}),
        field: "clients[0].addresses[0].peer") == "peer fc00::/7 is not an IPv4 prefix")
    end

    test "load refuses a bad route and a route with host bits" do
      assert(client_error(%({"name": "c", "routes": ["10.0.0.0/8", "10.0.0.0/33"]}),
        field: "clients[0].routes[1]") == %(invalid prefix "10.0.0.0/33": prefix length out of range))
      assert(client_error(%({"name": "c", "routes": ["10.0.0.1/8"]}),
        field: "clients[0].routes[0]") == "route 10.0.0.1/8 has host bits set")
    end

    test "load refuses an unknown user name and a uid out of range" do
      assert(client_error(%({"name": "c", "users": ["alice", "nobody-here"]}),
        field: "clients[0].users[1]") == %(unknown user "nobody-here"))
      assert(client_error(%({"name": "c", "users": ["4294967296"]}),
        field: "clients[0].users[0]") == "uid 4294967296 out of range")
    end

    test "load takes a users entry of ASCII digits as a uid and any other as a user name" do
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json(clients: %([{"name": "c", "users": ["0501", "alice", "0"]}])))

        assert(load(fixture).clients.first.users == [501_u32, 501_u32, 0_u32])
      end
      ["٥٠١", "501\n", "+501", " 501", "５０１"].each do |entry|
        assert(client_error(%({"name": "c", "users": [#{entry.to_json}]}), field: "clients[0].users[0]") ==
               %(unknown user #{entry.inspect}))
      end
    end

    test "load turns any failure of a user or group lookup into an error naming the field" do
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json(clients: %([{"name": "c", "users": ["alice"], "groups": ["staff"]}])))
        failing_user = Config::Loader.new(path: fixture.main, owner: fixture.owner,
          find_user: ->(name : String) : UInt32? { raise RuntimeError.new("getpwnam_r: Input/output error") },
          build_membership: ->(name : String) { STAFF }, open_directory: TunnelgeistFakeDirectory.opener)
        failing_group = Config::Loader.new(path: fixture.main, owner: fixture.owner,
          find_user: ->(name : String) : UInt32? { USERS[name]? },
          build_membership: ->(name : String) do
            raise RuntimeError.new("getgrnam_r: Input/output error") if name == "staff"
            STAFF
          end,
          open_directory: TunnelgeistFakeDirectory.opener)

        user_error = raised(Config::Error) { failing_user.load }
        group_error = raised(Config::Error) { failing_group.load }

        assert(user_error.message == "#{fixture.main}: field clients[0].users[0]: lookup failed: getpwnam_r: Input/output error")
        assert(user_error.cause.is_a?(RuntimeError))
        assert(group_error.message == "#{fixture.main}: field clients[0].groups[0]: lookup failed: getgrnam_r: Input/output error")
      end
    end

    test "load refuses an unknown group in a client" do
      assert(client_error(%({"name": "c", "groups": ["admin", "nosuch"]}),
        field: "clients[0].groups[1]") == "unknown group nosuch")
    end

    test "load refuses a signature requirement that does not compile" do
      assert(client_error(%({"name": "c", "signatures": ["anchor apple", "bad"]}),
        field: "clients[0].signatures") == %(requirement "bad" does not compile (OSStatus -67052)))
    end

    test "load refuses a mistyped client field" do
      assert(client_error(%({"name": "c", "routes": "10.0.0.0/8"}),
        field: "clients[0].routes", located: true) == "must be an array")
      assert(client_error(%({"name": "c", "addresses": {}}),
        field: "clients[0].addresses", located: true) == "must be an array")
      assert(client_error(%({"name": 1}), field: "clients[0].name", located: true) == "must be a string")
    end

    test "load refuses a users, groups, signatures or routes entry that is not a string" do
      ["users", "groups", "signatures", "routes"].each do |field|
        assert(client_error(%({"name": "c", "#{field}": ["0", 501]}), field: "clients[0].#{field}[1]", located: true) ==
               "must be a string")
      end
    end

    test "load refuses null for a required field as the wrong type" do
      assert(client_error(%({"name": null}), field: "clients[0].name", located: true) == "must be a string")
      assert(client_error(%({"name": "c", "addresses": [{"network": null}]}),
        field: "clients[0].addresses[0].network", located: true) == "must be a string")
    end

    test "load refuses a duplicate field in any object, naming the field and its line and column" do
      {
        main_json(clients: %([{"name": "c", "routes": ["10.0.0.0/8"], "routes": null}]))                        => "clients[0].routes",
        main_json(clients: %([{"name": "c", "addresses": [{"network": "10.0.0.0/8"}], "addresses": null}]))     => "clients[0].addresses",
        main_json(clients: %([{"name": "a"}]), extra: %(, "clients": null))                                     => "clients",
        main_json(extra: %(, "includes": ["c.json"], "includes": null))                                         => "includes",
        %({"socket": "/s", "socket": "/s", "group": "tg", "clients": [{"name": "c"}]})                          => "socket",
        main_json(clients: %([{"name": "c", "addresses": [{"network": "10.0.0.0/8", "network": "fc00::/7"}]}])) => "clients[0].addresses[0].network",
      }.each do |content, field|
        with_fixture do |fixture|
          fixture.write("config.json", content: content)
          fixture.write("c.json", content: %({"name": "i"}))
          key = field.split('.').last
          column = content.rindex!(%("#{key}")) + 1

          error = load_error(fixture)

          assert(error.field == field)
          assert(error.message == %(#{fixture.main}:1:#{column}: field #{field}: duplicate field "#{key}"))
        end
      end
    end

    test "load refuses a duplicate field in an included file" do
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json(extra: %(, "includes": ["c.json"])))
        included = fixture.write("c.json", content: %({"name": "c", "name": "d"}))

        assert(load_error(fixture).message == %(#{included}:1:15: field name: duplicate field "name"))
      end
    end

    # A guard of the JSON::Serializable text the loader maps to its own
    # reason: when a Crystal upgrade rewords it, this fails, not the users'
    # error messages.
    test "JSON::Serializable reports a missing field as the loader expects" do
      error = raised(JSON::SerializableError) { Config::Document::Main.from_json(%({"group": "tg"})) }

      assert(error.attribute == "socket")
      assert(error.cause.nil?)
      assert(error.message.to_s.starts_with?("Missing JSON attribute: socket\n"))
    end

    test "Error names the line and column of its location before the field" do
      error = Config::Error.new("bad", file: "/c.json", field: "f", location: Config::Location.new(line: 3, column: 5))

      assert(error.message == "/c.json:3:5: field f: bad")
      assert(Config::Error.new("bad", file: "/c.json", location: Config::Location.new(line: 3, column: 5)).message ==
             "/c.json:3:5: bad")
      assert(raised(NilAssertionError) { Config::Error.new("bad", file: "/c.json").location! })
    end

    # Ownership and mode (CC2)

    test "load refuses a main file others or the group can write" do
      [0o646, 0o664].each do |mode|
        with_fixture do |fixture|
          fixture.write("config.json", content: main_json)
          File.chmod(fixture.main, mode)

          error = load_error(fixture)

          assert(error.file == fixture.main)
          assert(error.field.nil?)
          assert(error.message == "#{fixture.main}: must be writable only by its owner, not mode #{"%04o" % mode}")
        end
      end
    end

    test "load refuses a main file in a directory others can write" do
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json)
        File.chmod(fixture.directory, 0o757)

        error = load_error(fixture)

        assert(error.file == fixture.directory)
        assert(error.message == "#{fixture.directory}: directory must be writable only by its owner, not mode 0757")
      end
    end

    test "load refuses a main file owned by another uid" do
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json)
        other = fixture.owner + 1
        statuses = {fixture.main => Config::FileStatus.new(type: File::Type::File, owner: other, mode: 0o644_u16, size: 10_i64)}

        error = raised(Config::Error) { Lookups.new.loader(fixture.main, owner: fixture.owner, statuses: statuses).load }

        assert(error.file == fixture.main)
        assert(error.message == "#{fixture.main}: must be owned by uid #{fixture.owner}, not uid #{other}")
      end
    end

    test "load refuses a main file in a directory another uid owns" do
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json)
        other = fixture.owner + 1
        statuses = {fixture.directory => Config::FileStatus.new(type: File::Type::Directory, owner: other,
          mode: 0o755_u16, size: 64_i64)}

        error = raised(Config::Error) { Lookups.new.loader(fixture.main, owner: fixture.owner, statuses: statuses).load }

        assert(error.file == fixture.directory)
        assert(error.message == "#{fixture.directory}: directory must be owned by root or uid #{fixture.owner}, not uid #{other}")
      end
    end

    test "load refuses a symbolic link in place of the main file" do
      with_fixture do |fixture|
        target = fixture.write("real.json", content: main_json)
        File.symlink(target, fixture.main)

        error = load_error(fixture)

        assert(error.file == fixture.main)
        assert(error.message == "#{fixture.main}: must be a regular file, not a symbolic link")
      end
    end

    test "load refuses a main file that does not exist" do
      with_fixture do |fixture|
        assert(load_error(fixture).message == "#{fixture.main}: does not exist")
      end
    end

    test "load names the main file as missing when a directory above it does not exist" do
      with_fixture do |fixture|
        path = File.join(fixture.directory, "missing", "config.json")

        error = raised(Config::Error) { Lookups.new.loader(path, owner: fixture.owner).load }

        assert(error.message == "#{path}: does not exist")
      end
    end

    test "load refuses the whole configuration when an include glob matches a file others can write" do
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json(extra: %(, "includes": ["clients.d/*.json"])))
        fixture.write("clients.d/a.json", content: %({"name": "a"}))
        writable = fixture.write("clients.d/b.json", content: %({"name": "b"}))
        File.chmod(writable, 0o666)

        error = load_error(fixture)

        assert(error.file == writable)
        assert(error.message == "#{writable}: must be writable only by its owner, not mode 0666")
      end
    end

    test "load refuses an include glob that matches a directory" do
      with_fixture do |fixture|
        fixture.write("config.json", content: main_json(extra: %(, "includes": ["clients.d/*"])))
        nested = fixture.write("clients.d/nested/a.json", content: %({"name": "a"}))

        error = load_error(fixture)

        assert(error.file == File.dirname(nested))
        assert(error.message == "#{File.dirname(nested)}: must be a regular file")
      end
    end

    test "load refuses a symbolic link in place of a directory above the main file" do
      with_fixture do |fixture|
        fixture.write("real/config.json", content: main_json)
        link = File.join(fixture.directory, "link")
        File.symlink(File.join(fixture.directory, "real"), link)

        error = raised(Config::Error) { Lookups.new.loader(File.join(link, "config.json"), owner: fixture.owner).load }

        assert(error.file == link)
        assert(error.message == "#{link}: must be a directory, not a symbolic link")
      end
    end

    # Address rules (CF3)

    test "AddressRule allows an IPv4 address inside the network with its peer inside the rule's peer" do
      rule = Config::AddressRule.new(network: prefix("10.1.0.0/16"), peer: prefix("10.1.0.0/16"))

      assert(rule.allows?(v4("10.1.2.3", bits: 24, peer: "10.1.2.1")))
      assert(rule.allows?(v4("10.1.2.3", bits: 16, peer: "10.1.2.1")))
      assert(!rule.allows?(v4("10.1.2.3", bits: 24, peer: "10.9.0.1")))
      assert(!rule.allows?(v4("10.2.2.3", bits: 24, peer: "10.1.2.1")))
    end

    test "AddressRule refuses an IPv4 address whose prefix is shorter than the rule's" do
      rule = Config::AddressRule.new(network: prefix("10.1.0.0/16"), peer: prefix("10.0.0.0/8"))

      assert(!rule.allows?(v4("10.1.2.3", bits: 8, peer: "10.1.2.1")))
    end

    test "AddressRule without a peer allows no IPv4 address" do
      rule = Config::AddressRule.new(network: prefix("10.0.0.0/8"), peer: nil)

      assert(!rule.allows?(v4("10.1.2.3", bits: 24, peer: "10.1.2.1")))
      assert(raised(NilAssertionError) { rule.peer! })
    end

    test "AddressRule allows an IPv6 address inside the network and refuses another family" do
      v6_rule = Config::AddressRule.new(network: prefix("fc00::/7"), peer: nil)
      v4_rule = Config::AddressRule.new(network: prefix("0.0.0.0/0"), peer: prefix("0.0.0.0/0"))

      assert(v6_rule.allows?(v6("fd12::1", bits: 64)))
      assert(!v6_rule.allows?(v6("fd12::1", bits: 6)))
      assert(!v6_rule.allows?(v6("2001:db8::1", bits: 64)))
      assert(!v6_rule.allows?(v4("10.1.2.3", bits: 24, peer: "10.1.2.1")))
      assert(!v4_rule.allows?(v6("fd12::1", bits: 64)))
      assert(v4_rule.allows?(v4("10.1.2.3", bits: 24, peer: "10.1.2.1")))
    end

    # Which clients apply (CF4)

    # A group without members.
    def nogroup : Tunnelgeist::Membership
      TunnelgeistFakeMembership.new("nogroup", gid: 4_294_967_294_u32, members: [] of UInt32).as(Tunnelgeist::Membership)
    end

    test "Client applies to everyone when it lists no users, groups or signatures" do
      assert(client.applies?(fake_peer, inspection: nil).nil?)
    end

    test "Client applies when the peer's uid is one of its users and refuses it otherwise" do
      peer = fake_peer
      assert(client(users: [PEER_UID + 1, PEER_UID]).applies?(peer, inspection: nil).nil?)

      refusal = client(users: [PEER_UID + 1]).applies?(peer, inspection: nil)
      assert(refusal == refused(Reason::Users))
      assert(refusal.to_s == "users")
      assert(client(users: [] of UInt32).applies?(peer, inspection: nil) == refused(Reason::Users))
    end

    test "Client applies when the peer is in one of its groups and refuses it otherwise" do
      peer = fake_peer
      assert(client(groups: [nogroup, STAFF]).applies?(peer, inspection: nil).nil?)

      refusal = client(groups: [nogroup]).applies?(peer, inspection: nil)
      assert(refusal == refused(Reason::Groups))
      assert(refusal.to_s == "groups")
    end

    test "Client needs every kind it lists and reports the first that fails" do
      peer = fake_peer

      assert(client(users: [PEER_UID], groups: [STAFF]).applies?(peer, inspection: nil).nil?)
      assert(client(users: [PEER_UID], groups: [nogroup]).applies?(peer, inspection: nil) == refused(Reason::Groups))
      assert(client(users: [PEER_UID + 1], groups: [nogroup]).applies?(peer, inspection: nil) == refused(Reason::Users))
    end

    test "Client needs the peer's inspection when it lists signatures" do
      peer = fake_peer
      error = raised(ArgumentError) do
        client(policy: Tunnelgeist::SignaturePolicy.new(["anchor apple generic"])).applies?(peer, inspection: nil)
      end

      assert(error.message.to_s.includes?("client c"))
      raised(ArgumentError) { client(policy: Tunnelgeist::SignaturePolicy.new([] of String)).applies?(peer, inspection: nil) }
    end
  {% end %}
end
