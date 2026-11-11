require "file_utils"
require "../test_helper"
require "../../src/tunnelgeist/config"
require "../../src/tunnelgeist/config/address_rule"
require "../../src/tunnelgeist/config/client"
require "../../src/tunnelgeist/config/error"
require "../../src/tunnelgeist/config/file_guard"
require "../../src/tunnelgeist/config/loader"
require "../../src/tunnelgeist/lib_system"
require "../../src/tunnelgeist/membership"
require "../../src/tunnelgeist/signature_policy"
require "../../src/tunnelgeist/signature_policy/inspection"
require "./support/own_peer"
require "./support/temporary_directory"

# The configuration loader and the client configuration (CA1, CC2, CF4) with
# what the unit specs stub: the system's users and groups (every macOS user is
# in `staff`, nobody in `nogroup`), Security on this ad-hoc signed process,
# the effective uid and the root-owned `/private/tmp`.
describe TunnelgeistConfig do
  {% if flag?(:darwin) %}
    include TunnelgeistOwnPeer
    include TunnelgeistTemporaryDirectory

    alias Config = Tunnelgeist::Config
    alias Reason = Tunnelgeist::Refusal::Reason

    # A requirement no process of this suite meets.
    UNMET_REQUIREMENT = %(identifier "io.github.jochenseeber.tunnelgeist.nobody")

    # Writes *content* to *name* below *directory* with mode 0644, creating
    # its directories with mode 0755, and returns the path.
    def write(directory : String, *, name : String, content : String) : String
      path = File.join(directory, name)
      parent = File.dirname(path)
      Dir.mkdir_p(parent)
      File.chmod(parent, 0o755)
      File.write(path, content)
      File.chmod(path, 0o644)
      path
    end

    # A loader of *path* with the system's user lookup and every group
    # resolved to `staff`.
    def staff_loader(path : String) : Config::Loader
      Config::Loader.new(path: path, build_membership: ->(_name : String) { Tunnelgeist::Membership.new("staff") })
    end

    def client(*, users : Array(UInt32)? = nil, groups : Array(Tunnelgeist::Membership)? = nil,
               policy : Tunnelgeist::SignaturePolicy? = nil) : Config::Client
      Config::Client.new(name: "c", users: users, groups: groups, policy: policy,
        addresses: [] of Config::AddressRule, routes: [] of Tunnelgeist::Prefix)
    end

    def refused(reason : Reason) : Tunnelgeist::Refusal
      Tunnelgeist::Refusal.new(reason: reason)
    end

    # Runs the block with the signing information of *peer*, closed after it.
    def with_inspection(peer : Tunnelgeist::Peer, &)
      inspection = Tunnelgeist::SignaturePolicy::Inspection.of(peer)
      begin
        yield inspection
      ensure
        inspection.close
      end
    end

    test "Config.load reads the file at the path" do
      with_temporary_directory do |directory|
        main = write(directory, name: "config.json",
          content: %({"socket": "/var/run/tg.sock", "group": "staff", "clients": [{"name": "default"}]}))

        config = Config.load(main)

        assert(config.group == "staff")
        assert(config.clients.map(&.name) == ["default"])
      end
    end

    test "Config.load takes the main group and client groups by gid and names the main group by its name" do
      with_temporary_directory do |directory|
        staff = System::Group.find_by(name: "staff").id
        main = write(directory, name: "config.json", content: %({"socket": "/var/run/tg.sock", "group": "#{staff}",
          "clients": [{"name": "default", "groups": ["#{staff}"]}]}))

        config = Config.load(main)

        assert(config.group == "staff")
        assert(config.membership.gid == staff.to_u32)
        assert(config.clients[0].groups!.map(&.gid) == [staff.to_u32])
      end
    end

    test "load refuses an include glob in a directory it cannot read" do
      if Tunnelgeist::LibSystem.geteuid == 0
        skip "root reads every directory"
      end
      with_temporary_directory do |directory|
        main = write(directory, name: "config.json",
          content: %({"socket": "/var/run/tg.sock", "group": "tg", "includes": ["clients.d/*.json"]}))
        write(directory, name: "clients.d/a.json", content: %({"name": "a"}))
        locked = File.join(directory, "clients.d")
        File.chmod(locked, 0o000)
        begin
          error = raised(Config::Error) { staff_loader(main).load }

          assert(error.file == main)
          assert(error.field == "includes[0]")
          assert(error.reason.starts_with?("cannot be resolved: "))
          assert(error.reason.ends_with?("Permission denied"))
        ensure
          File.chmod(locked, 0o755)
        end
      end
    end

    test "load refuses a user name with a NUL byte through the system lookup" do
      with_temporary_directory do |directory|
        main = write(directory, name: "config.json", content: %({"socket": "/var/run/tg.sock", "group": "tg",
          "clients": [{"name": "c", "users": ["0", "a\\u0000b"]}]}))

        error = raised(Config::Error) { staff_loader(main).load }

        assert(error.message == "#{main}: field clients[0].users[1]: String contains null byte")
      end
    end

    test "FileGuard.check refuses a file the owner owns in a directory another uid owns" do
      # A directory of another owner needs chown, so this uses the system's
      # root-owned /private/tmp, whose owner the guard checks before its mode.
      euid = Tunnelgeist::LibSystem.geteuid
      if euid == 0
        skip "root owns /private/tmp"
      end
      path = File.join("/private/tmp", "tg-config-#{Random::Secure.hex(4)}.json")
      File.write(path, "{}")
      File.chmod(path, 0o644)
      begin
        error = raised(Config::Error) { Config::FileGuard.check(path, owner: euid) }

        assert(error.file == "/private/tmp")
        assert(error.message == "/private/tmp: must be owned by uid #{euid}, not uid 0")
      ensure
        File.delete(path)
      end
    end

    test "Client refuses with the signature policy's refusal, and refuses everyone with an empty policy" do
      unmet = Tunnelgeist::SignaturePolicy.new([UNMET_REQUIREMENT])
      met = Tunnelgeist::SignaturePolicy.new(["always"])

      with_own_peer do |peer|
        with_inspection(peer) do |inspection|
          assert(client(policy: unmet).applies?(peer, inspection: inspection) == refused(Reason::Requirement))
          assert(client(policy: met).applies?(peer, inspection: inspection) == refused(Reason::HardenedRuntime))
          assert(client(policy: Tunnelgeist::SignaturePolicy.new([] of String)).applies?(peer, inspection: inspection) ==
                 refused(Reason::Requirement))
        end
      end
    end

    test "Client checks the users and groups before the signature policy" do
      staff = Tunnelgeist::Membership.new("staff")
      nogroup = Tunnelgeist::Membership.new("nogroup")
      unmet = Tunnelgeist::SignaturePolicy.new([UNMET_REQUIREMENT])

      with_own_peer do |peer|
        with_inspection(peer) do |inspection|
          assert(client(users: [peer.uid + 1], groups: [nogroup], policy: unmet).applies?(peer, inspection: inspection) ==
                 refused(Reason::Users))
          assert(client(users: [peer.uid], groups: [nogroup], policy: unmet).applies?(peer, inspection: inspection) ==
                 refused(Reason::Groups))
          assert(client(users: [peer.uid], groups: [staff], policy: unmet).applies?(peer, inspection: inspection) ==
                 refused(Reason::Requirement))
        end
      end
    end
  {% end %}
end
