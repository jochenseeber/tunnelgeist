require "file_utils"
require "../spec_helper"
require "../../src/tunnelgeist/config"
require "../../src/tunnelgeist/config/loader"
require "./support/fake_directory"
require "./support/fake_membership"
require "./support/temporary_directory"

# The example configuration in `examples/config`: it loads as the daemon
# loads it, so the examples stay valid.
module ExampleConfigs
end

describe ExampleConfigs do
  {% if flag?(:darwin) %}
    # The example files, copied into a temporary directory with modes 0755
    # and 0644, as the loader's mode checks need.
    def with_examples(&)
      TunnelgeistTemporaryDirectory.with_temporary_directory do |root|
        directory = File.join(root, "config")
        FileUtils.cp_r(File.join(__DIR__, "..", "..", "examples", "config"), directory)
        File.chmod(directory, 0o755)
        Dir.glob(File.join(directory, "**", "*")).each do |path|
          File.chmod(path, File.directory?(path) ? 0o755 : 0o644)
        end
        yield File.join(directory, "config.json")
      end
    end

    # Loads *path* with the real signature requirements, owned by the owner
    # of its directory, through a `TunnelgeistFakeDirectory`. Every group
    # resolves to a stand-in for `staff`; the names asked for are kept in
    # *groups*. The examples name their users by uid, so the user lookup is
    # never asked.
    def load(path : String, *, groups : Array(String)) : Tunnelgeist::Config
      Tunnelgeist::Config::Loader.new(path: path, owner: File.info(File.dirname(path)).owner_id.to_u32,
        find_user: ->(name : String) : UInt32? { raise "the examples name the user #{name}, not a uid" },
        build_membership: ->(name : String) do
          groups << name
          TunnelgeistFakeMembership.new("staff", gid: 20_u32, members: [] of UInt32).as(Tunnelgeist::Membership)
        end,
        open_directory: TunnelgeistFakeDirectory.opener).load
    end

    test "the example configuration loads with the main file's client and both includes" do
      with_examples do |path|
        groups = [] of String
        config = load(path, groups: groups)

        assert(config.socket == "/var/run/tunnelgeist.sock")
        assert(config.group == "staff")
        assert(config.clients.map(&.name) == ["admins", "vm", "vpn"])
        assert(groups == ["tunnelgeist", "admin", "staff"])
      end
    end

    test "the example clients restrict by users, groups and signatures" do
      with_examples do |path|
        clients = load(path, groups: [] of String).clients.to_h { |client| {client.name, client} }

        assert(clients["vm"].users == [501_u32])
        assert(clients["vpn"].policy)
        assert(clients["vpn"].routes.map(&.to_s) == ["10.20.0.0/16", "10.21.0.0/16", "fd00:20::/48"])
      end
    end
  {% end %}
end
