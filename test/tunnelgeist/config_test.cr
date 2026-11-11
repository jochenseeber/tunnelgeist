require "file_utils"
require "../test_helper"
require "../../src/tunnelgeist/config"
require "../../src/tunnelgeist/config/address_rule"
require "../../src/tunnelgeist/config/client"
require "../../src/tunnelgeist/config/error"
require "../../src/tunnelgeist/config/loader"
require "../../src/tunnelgeist/lib_system"
require "../../src/tunnelgeist/membership"
require "../../src/tunnelgeist/signature_policy"
require "../../src/tunnelgeist/signature_policy/inspection"
require "./support/own_peer"
require "./support/trusted_temporary_directory"
require "./support/temporary_directory"

# The configuration loader and the client configuration (CA1, CC2, CF4) with
# what the unit specs stub: the system's users and groups (every macOS user is
# in `staff`, nobody in `nogroup`), Security on this ad-hoc signed process,
# the effective uid, ACLs set with `/bin/chmod +a`, the world-writable
# `/private/tmp` and the directories above the temporary directory.
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

    # Runs the block with a new temporary directory the configuration walk
    # accepts, mode 0755.
    def with_trusted_directory(&)
      with_temporary_directory do |directory|
        File.chmod(directory, 0o755)
        TunnelgeistTrustedTemporaryDirectory.check_trusted(directory, owner: Tunnelgeist::LibSystem.geteuid)
        yield directory
      end
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

          assert(error.file == locked)
          assert(error.message == "#{locked}: cannot be opened: Permission denied")
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

    test "load refuses a main file in /private/tmp, which everyone may write" do
      error = raised(Config::Error) { staff_loader("/private/tmp/tunnelgeist-config.json").load }

      assert(error.file == "/private/tmp")
      assert(error.message == "/private/tmp: directory must be writable only by its owner, not mode 1777")
    end

    test "load reads relative, absolute and glob includes through checked directories" do
      with_trusted_directory do |directory|
        main = write(directory, name: "etc/config.json", content: %({"socket": "/var/run/tg.sock", "group": "tg",
          "includes": ["more/one.json", "#{directory}/abs/two.json", "./clients.d/*.json"]}))
        write(directory, name: "etc/more/one.json", content: %({"name": "one"}))
        write(directory, name: "abs/two.json", content: %({"name": "two"}))
        write(directory, name: "etc/clients.d/b.json", content: %({"name": "b"}))
        write(directory, name: "etc/clients.d/a.json", content: %({"name": "a"}))

        assert(staff_loader(main).load.clients.map(&.name) == ["one", "two", "a", "b"])
      end
    end

    test "load refuses an include below a directory the walk refuses, naming that directory" do
      with_trusted_directory do |directory|
        main = write(directory, name: "config.json", content: %({"socket": "/var/run/tg.sock", "group": "tg",
          "includes": ["clients.d/*.json"]}))
        included = write(directory, name: "clients.d/a.json", content: %({"name": "a"}))
        File.chmod(File.dirname(included), 0o775)

        error = raised(Config::Error) { staff_loader(main).load }

        assert(error.message == "#{File.dirname(included)}: directory must be writable only by its owner, not mode 0775")
      end
    end

    test "load refuses an absolute include in /private/tmp, walking to it from /" do
      with_trusted_directory do |directory|
        main = write(directory, name: "config.json", content: %({"socket": "/var/run/tg.sock", "group": "tg",
          "clients": [{"name": "c"}], "includes": ["/private/tmp/*.json"]}))

        error = raised(Config::Error) { staff_loader(main).load }

        assert(error.message == "/private/tmp: directory must be writable only by its owner, not mode 1777")
      end
    end

    test "load refuses a .. component in an include" do
      with_trusted_directory do |directory|
        main = write(directory, name: "etc/config.json", content: %({"socket": "/var/run/tg.sock", "group": "tg",
          "includes": ["../c.json"]}))
        write(directory, name: "c.json", content: %({"name": "c"}))

        error = raised(Config::Error) { staff_loader(main).load }

        assert(error.message == "#{main}: field includes[0]: must not contain a .. component")
      end
    end

    test "load refuses an included file whose ACL lets everyone write" do
      with_trusted_directory do |directory|
        main = write(directory, name: "config.json", content: %({"socket": "/var/run/tg.sock", "group": "tg",
          "includes": ["c.json"]}))
        included = write(directory, name: "c.json", content: %({"name": "c"}))
        status = Process.run("/bin/chmod", ["+a", "everyone allow write", included], error: Process::Redirect::Inherit)
        raise "chmod +a #{included} failed" unless status.success?

        error = raised(Config::Error) { staff_loader(main).load }

        assert(error.message == "#{included}: grants write access through its ACL")
      end
    end

    test "load takes a relative main path from the physical working directory, not from PWD" do
      with_trusted_directory do |directory|
        real = File.join(directory, "real")
        write(directory, name: "real/config.json", content: %({"socket": "/var/run/tg.sock", "group": "tg",
          "clients": [{"name": "c"}]}))
        link = File.join(directory, "link")
        File.symlink(real, link)
        logical = ENV["PWD"]?
        begin
          Dir.cd(real) do
            # A shell started in the link would say so in PWD, which
            # `Dir.current` returns when it names the working directory.
            ENV["PWD"] = link

            assert(staff_loader("config.json").load.clients.map(&.name) == ["c"])
            assert(raised(Config::Error) { staff_loader("missing.json").load }.message == "#{real}/missing.json: does not exist")
          end
        ensure
          if logical
            ENV["PWD"] = logical
          else
            ENV.delete("PWD")
          end
        end
      end
    end

    test "load refuses a main path or an include that ends in / when it names a file, as cat does" do
      with_trusted_directory do |directory|
        main = write(directory, name: "config.json", content: %({"socket": "/var/run/tg.sock", "group": "tg",
          "includes": ["c.json/"]}))
        write(directory, name: "c.json", content: %({"name": "c"}))

        assert(raised(Config::Error) { staff_loader("#{main}/").load }.message == "#{main}: must be a directory")
        assert(raised(Config::Error) { staff_loader(main).load }.message == "#{directory}/c.json: must be a directory")
      end
    end

    test "load refuses a main file over 1 MiB" do
      with_trusted_directory do |directory|
        main = write(directory, name: "config.json", content: " " * 1_048_577)

        error = raised(Config::Error) { staff_loader(main).load }

        assert(error.message == "#{main}: must be at most 1 MiB (1048576 bytes)")
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
