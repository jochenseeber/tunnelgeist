require "../test_helper"
require "file_utils"
require "json"
require "../../src/tunnelgeist/config"
require "../../src/tunnelgeist/install"
require "../../src/tunnelgeist/install/starter"
require "../../src/tunnelgeist/membership"
require "../../spec/tunnelgeist/support/fake_membership"
require "./support/temporary_directory"

# `install` as root against a temporary directory with a recording runner,
# and the property list checked by the system's `plutil`. Before it writes
# anything, `install` checks every directory above the ones it writes in up
# to `/`, so these tests depend on the real directories above the temporary
# directory: its ancestors must be owned by root or the user and writable by
# no one else, as macOS's per-user `$TMPDIR` below `/private/var/folders` is.
# The real configuration loader asks the system for the group `staff`.
describe TunnelgeistInstall do
  {% if flag?(:darwin) %}
    alias Install = Tunnelgeist::Install

    # The top-level dict of the plist in *xml* as key => value node.
    def top_dict(xml : String) : Hash(String, XML::Node)
      root = XML.parse(xml).first_element_child || raise "the plist has no root element"
      dict = root.children.find(&.name.==("dict")) || raise "the plist has no dict"
      entries(dict)
    end

    # The key => value nodes of *dict*.
    def entries(dict : XML::Node) : Hash(String, XML::Node)
      elements = dict.children.select(&.element?)
      result = {} of String => XML::Node
      elements.each_slice(2) { |(key, value)| result[key.content] = value }
      result
    end

    # The string contents of the array *node*.
    def strings(node : XML::Node) : Array(String)
      node.children.select(&.element?).map(&.content)
    end

    LAUNCHCTL   = "/bin/launchctl"
    DSEDITGROUP = "/usr/sbin/dseditgroup"
    BOOTOUT     = [LAUNCHCTL, "bootout", "system/io.github.jochenseeber.tunnelgeist"]

    # A command runner that records every argument vector and answers with
    # the result its block gives.
    class Recorder
      getter calls = [] of Array(String)

      def initialize(&@answer : Array(String) -> Tunnelgeist::CommandRunner::Result)
      end

      def run : Tunnelgeist::CommandRunner::Run
        ->(argv : Array(String)) do
          @calls << argv
          @answer.call(argv)
        end
      end
    end

    def succeeded : Tunnelgeist::CommandRunner::Result
      Tunnelgeist::CommandRunner::Result.new(exit_status: 0, output: "", error: "")
    end

    def failed(status : Int32, *, error : String) : Tunnelgeist::CommandRunner::Result
      Tunnelgeist::CommandRunner::Result.new(exit_status: status, output: "", error: error)
    end

    # The outcome of one `install` or `uninstall`.
    record Outcome, status : Int32, output : String, error : String do
      def lines : Array(String)
        output.lines
      end
    end

    # A temporary installation layout: a fresh temporary directory with mode
    # 0755, *root* with mode 0755 below it, the binary below that, the
    # property list in a directory of its own, the configuration two missing
    # directories down, the socket the configuration names, and a file
    # standing in for the running executable.
    class Layout
      getter directory : String
      getter paths : Install::Paths
      getter socket : String
      getter executable : String

      def initialize
        @directory = TunnelgeistTemporaryDirectory.create_temporary_directory
        root = File.join(@directory, "usr")
        Dir.mkdir_p(root, 0o755)
        File.chmod(@directory, 0o755)
        File.chmod(root, 0o755)
        Dir.mkdir_p(File.join(@directory, "LaunchDaemons"), 0o755)
        @paths = Install::Paths.new(binary: File.join(root, "libexec", "tunnelgeist"),
          plist: File.join(@directory, "LaunchDaemons", "daemon.plist"),
          config: File.join(@directory, "etc", "tunnelgeist", "config.json"), log: File.join(@directory, "t.log"),
          root: root)
        @socket = File.join(@directory, "t.sock")
        @executable = File.join(@directory, "executable")
        File.write(@executable, "the daemon")
      end

      # The user and group that own the layout's directory, and so every
      # file the spec creates in it.
      def owner : Install::Owner
        info = File.info(@directory)
        Install::Owner.new(uid: info.owner_id.to_u32, gid: info.group_id.to_u32)
      end

      def remove : Nil
        FileUtils.rm_rf(@directory)
      end
    end

    # A loaded configuration with *socket* and *group*, whose membership has
    # gid 20.
    def loaded(*, socket : String, group : String = "tunnelgeist") : Tunnelgeist::Config
      Tunnelgeist::Config.new(socket: socket, group: group,
        membership: TunnelgeistFakeMembership.new(group, gid: 20_u32, members: [] of UInt32),
        clients: [] of Tunnelgeist::Config::Client)
    end

    # A configuration loader that records the paths it is asked for and
    # answers with the configuration its block gives.
    class Loads
      getter paths = [] of String

      def initialize(&@answer : String -> Tunnelgeist::Config)
      end

      def load : String -> Tunnelgeist::Config
        ->(path : String) do
          @paths << path
          @answer.call(path)
        end
      end
    end

    # A loader that answers with `loaded` for the socket of *layout*.
    def loads(layout : Layout) : Loads
      Loads.new { loaded(socket: layout.socket) }
    end

    # An `Install` that believes it runs as *uid*, writes into *layout*,
    # finds the group with *find_group* and loads the configuration with
    # *load_config*, by default a configuration naming the socket of
    # *layout*.
    def installer(layout : Layout, *, recorder : Recorder, uid : UInt32 = 0_u32,
                  find_group : String -> UInt32? = ->(_name : String) : UInt32? { 20_u32 },
                  lint : String -> String? = ->(_xml : String) : String? { nil },
                  load_config : String -> Tunnelgeist::Config = loads(layout).load) : Install
      Install.new(run: recorder.run, effective_uid: -> { uid }, paths: layout.paths, owner: layout.owner,
        executable: layout.executable, find_group: find_group, lint: lint, load_config: load_config)
    end

    def install(installer : Install, *, group : String = "tunnelgeist", sudo_user : String? = nil) : Outcome
      output = IO::Memory.new
      error = IO::Memory.new
      status = installer.install(group: group, sudo_user: sudo_user, output: output, error: error)
      Outcome.new(status: status, output: output.to_s, error: error.to_s)
    end

    def with_layout(&)
      layout = Layout.new
      begin
        yield layout
      ensure
        layout.remove
      end
    end

    # The property list of a real installation for the socket and gid of
    # the starter configuration.
    def default_plist(*, group_gid : UInt32 = 20_u32) : String
      Install.new.plist(config_path: Tunnelgeist::Config::DEFAULT_PATH, socket: "/var/run/tunnelgeist.sock",
        group_gid: group_gid)
    end

    # CF6, the starter configuration of the design, as the design writes it.
    CF6 = <<-JSON
      {
        "socket": "/var/run/tunnelgeist.sock",
        "group": "tunnelgeist",
        "includes": ["clients.d/*.json"],
        "clients": [
          {
            "name": "default",
            "addresses": [
              { "network": "10.0.0.0/8", "peer": "10.0.0.0/8" },
              { "network": "172.16.0.0/12", "peer": "172.16.0.0/12" },
              { "network": "192.168.0.0/16", "peer": "192.168.0.0/16" },
              { "network": "fc00::/7" }
            ],
            "routes": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7"]
          }
        ]
      }
      JSON

    # The starter configuration for *group* as `JSON.build` lays it out:
    # CF6 with every array element on its own line.
    def starter_text(group : String) : String
      <<-JSON
        {
          "socket": "/var/run/tunnelgeist.sock",
          "group": "#{group}",
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

        JSON
    end

    # Runs the block with the file mode creation mask *mask*, then restores
    # the previous one.
    def with_umask(mask : Int32, &)
      previous = LibC.umask(mask)
      begin
        yield
      ensure
        LibC.umask(previous)
      end
    end

    # The text `install` reports for a directory *path* it refuses, for
    # *reason*.
    def refused_directory(path : String, *, reason : String) : String
      "tunnelgeist: #{path} must be a directory owned by root and writable only by root: #{reason}\n"
    end

    # An `Install` for *layout* whose group is missing and whose loader
    # records its calls in *loads*, so a spec sees whether it created the
    # group or loaded anything.
    def checking_installer(layout : Layout, *, recorder : Recorder, loads : Loads) : Install
      installer(layout, recorder: recorder, find_group: ->(_name : String) : UInt32? { nil }, load_config: loads.load)
    end

    # Whether `plutil -lint` accepts *xml*, read from its standard input.
    def lints?(xml : String) : Bool
      output = IO::Memory.new
      status = Process.run("/usr/bin/plutil", ["-lint", "-"], input: IO::Memory.new(xml), output: output, error: output)
      status.success?
    end

    # The loader `install` uses unless told otherwise, `Config.load`.
    def real_load : String -> Tunnelgeist::Config
      ->(path : String) { Tunnelgeist::Config.load(path) }
    end

    test "plist passes plutil -lint" do
      assert(lints?(default_plist))
      assert(lints?(default_plist(group_gid: 501_u32)))
    end

    test "plist with the XML special characters in its paths passes plutil -lint" do
      paths = Install::Paths.new(binary: "/opt/a & b <x>/tunnelgeist", plist: "/tmp/tg.plist", config: "/tmp/tg.json",
        log: "/tmp/tg.log", root: "/opt")
      xml = Install.new(paths: paths).plist(config_path: "/tmp/a & b.json", socket: "/tmp/<tg>.sock", group_gid: 20_u32)

      assert(lints?(xml))
    end

    test "lint accepts the plist and reports a broken one" do
      good = default_plist
      broken = Install.lint(good.sub("</plist>", ""))

      assert(Install.lint(good).nil?)
      assert(!broken.nil?)
    end

    test "install loads the starter it wrote with Config.load" do
      with_layout do |layout|
        outcome = install(installer(layout, recorder: Recorder.new { succeeded }, load_config: real_load), group: "staff")
        listeners = entries(entries(top_dict(File.read(layout.paths.plist))["Sockets"])["Listeners"])

        assert(outcome.status == 0)
        assert(outcome.error.empty?)
        assert(listeners["SockPathName"].content == "/var/run/tunnelgeist.sock")
        assert(listeners["SockPathGroup"].content == Tunnelgeist::Membership.new("staff").gid.to_s)
        assert(outcome.lines.last == "  sudo #{DSEDITGROUP} -o edit -a USER -t user staff")
      end
    end

    test "install writes the starter, copies the binary, unloads, writes the plist and loads it, in that order" do
      with_layout do |layout|
        # What the paths held when launchctl bootout ran.
        binary_at_bootout = nil
        plist_at_bootout = nil
        recorder = Recorder.new do |argv|
          if argv == BOOTOUT
            binary_at_bootout = File.exists?(layout.paths.binary)
            plist_at_bootout = File.exists?(layout.paths.plist)
          end
          succeeded
        end
        # Whether the starter was there when the configuration was loaded.
        starter_at_load = nil
        load_config = Loads.new do |path|
          starter_at_load = File.exists?(path)
          loaded(socket: layout.socket)
        end
        outcome = install(installer(layout, recorder: recorder, load_config: load_config.load), sudo_user: "someone")

        assert(outcome.status == 0)
        assert(load_config.paths == [layout.paths.config])
        assert(starter_at_load == true)
        assert(binary_at_bootout == true)
        assert(plist_at_bootout == false)
        assert(outcome.error.empty?)
        assert(recorder.calls == [BOOTOUT, [LAUNCHCTL, "bootstrap", "system", layout.paths.plist]])
        assert(outcome.lines == [
          "wrote #{layout.paths.config}",
          "installed #{layout.paths.binary}",
          "wrote #{layout.paths.plist}",
          "loaded io.github.jochenseeber.tunnelgeist; launchd listens on #{layout.socket}",
          "Add a user to the group tunnelgeist with:",
          "  sudo #{DSEDITGROUP} -o edit -a someone -t user tunnelgeist",
        ])
        assert(File.read(layout.paths.binary) == "the daemon")
        assert(File.info(layout.paths.binary).permissions.value == 0o755)
        assert(File.info(layout.paths.plist).permissions.value == 0o644)
        top = top_dict(File.read(layout.paths.plist))
        assert(strings(top["ProgramArguments"]) == [layout.paths.binary, "serve", "--config", layout.paths.config])
        assert(top["StandardErrorPath"].content == layout.paths.log)
        assert(Dir.children(File.dirname(layout.paths.plist)) == ["daemon.plist"])
      end
    end

    test "install writes the starter for its group, mode 0644, with the owner" do
      with_layout do |layout|
        outcome = install(installer(layout, recorder: Recorder.new { succeeded }), group: "helpers")
        info = File.info(layout.paths.config, follow_symlinks: false)

        assert(outcome.status == 0)
        assert(File.read(layout.paths.config) == starter_text("helpers"))
        assert(info.permissions.value == 0o644)
        assert(info.owner_id == layout.owner.uid.to_s)
        assert(info.group_id == layout.owner.gid.to_s)
        assert(Dir.children(layout.paths.config_directory).sort! == ["clients.d", "config.json"])
      end
    end

    test "install creates the configuration directories, mode 0755, with the owner" do
      with_layout do |layout|
        # Under this mask only an explicit mode change yields 0755.
        outcome = with_umask(0o077) { install(installer(layout, recorder: Recorder.new { succeeded })) }

        assert(outcome.status == 0)
        directories = [File.dirname(layout.paths.config_directory), layout.paths.config_directory,
                       layout.paths.clients_directory]

        directories.each do |directory|
          info = File.info(directory, follow_symlinks: false)
          assert(info.directory?)
          assert(info.permissions.value == 0o755)
          assert(info.owner_id == layout.owner.uid.to_s)
          assert(info.group_id == layout.owner.gid.to_s)
        end
        assert(Dir.children(layout.paths.clients_directory).empty?)
      end
    end

    test "install keeps an existing configuration and says so" do
      with_layout do |layout|
        Dir.mkdir_p(layout.paths.config_directory, 0o755)
        File.write(layout.paths.config, "the operator's configuration")
        File.chmod(layout.paths.config, 0o600)
        outcome = install(installer(layout, recorder: Recorder.new { succeeded }))

        assert(outcome.status == 0)
        assert(outcome.lines.first == "kept #{layout.paths.config}")
        assert(!outcome.lines.includes?("wrote #{layout.paths.config}"))
        assert(File.read(layout.paths.config) == "the operator's configuration")
        assert(File.info(layout.paths.config).permissions.value == 0o600)
        assert(Dir.exists?(layout.paths.clients_directory))
      end
    end

    test "install takes the socket and the group of an existing configuration over --group" do
      with_layout do |layout|
        Dir.mkdir_p(layout.paths.config_directory, 0o755)
        File.write(layout.paths.config, "staff's configuration")
        socket = File.join(layout.directory, "staff.sock")
        find_group = ->(name : String) : UInt32? { name == "tunnelgeist" ? 777_u32 : nil }
        load_config = Loads.new { loaded(socket: socket, group: "staff") }
        outcome = install(installer(layout, recorder: Recorder.new { succeeded }, find_group: find_group,
          load_config: load_config.load), group: "tunnelgeist")
        listeners = entries(entries(top_dict(File.read(layout.paths.plist))["Sockets"])["Listeners"])

        assert(outcome.status == 0)
        assert(listeners["SockPathName"].content == socket)
        assert(listeners["SockPathGroup"].content == "20")
        assert(outcome.lines[-3..] == [
          "loaded io.github.jochenseeber.tunnelgeist; launchd listens on #{socket}",
          "Add a user to the group staff with:",
          "  sudo #{DSEDITGROUP} -o edit -a USER -t user staff",
        ])
      end
    end

    test "install stops before it copies or unloads anything when the configuration does not load" do
      with_layout do |layout|
        recorder = Recorder.new { succeeded }
        load_config = Loads.new do |path|
          raise Tunnelgeist::Config::Error.new("must be owned by uid 0, not uid 501", file: File.dirname(path))
        end
        outcome = install(installer(layout, recorder: recorder, load_config: load_config.load))

        assert(outcome.status == 1)
        assert(outcome.error == "tunnelgeist: #{layout.paths.config_directory}: must be owned by uid 0, not uid 501\n")
        assert(outcome.lines == ["wrote #{layout.paths.config}"])
        assert(recorder.calls.empty?)
        assert(!File.exists?(layout.paths.binary))
        assert(!File.exists?(layout.paths.plist))
      end
    end

    test "install refuses an existing configuration directory others may write before it changes anything" do
      with_layout do |layout|
        Dir.mkdir_p(layout.paths.config_directory, 0o755)
        File.chmod(layout.paths.config_directory, 0o775)
        recorder = Recorder.new { succeeded }
        load_config = loads(layout)
        outcome = install(checking_installer(layout, recorder: recorder, loads: load_config))

        assert(outcome.status == 1)
        assert(outcome.error == refused_directory(layout.paths.config_directory, reason: "its mode is 0775"))
        assert(outcome.output.empty?)
        assert(File.info(layout.paths.config_directory).permissions.value == 0o775)
        assert(Dir.children(layout.paths.config_directory).empty?)
        assert(recorder.calls.empty?)
        assert(load_config.paths.empty?)
        assert(!File.exists?(layout.paths.binary))
        assert(!File.exists?(layout.paths.plist))
      end
    end

    test "install refuses a configuration directory that is a symbolic link before it writes anything" do
      with_layout do |layout|
        target = File.join(layout.directory, "elsewhere")
        Dir.mkdir_p(target, 0o755)
        Dir.mkdir_p(File.dirname(layout.paths.config_directory), 0o755)
        File.symlink(target, layout.paths.config_directory)
        recorder = Recorder.new { succeeded }
        load_config = loads(layout)
        outcome = install(checking_installer(layout, recorder: recorder, loads: load_config))

        assert(outcome.status == 1)
        assert(outcome.error == refused_directory(layout.paths.config_directory, reason: "it is a symbolic link"))
        assert(outcome.output.empty?)
        assert(Dir.children(target).empty?)
        assert(recorder.calls.empty?)
        assert(load_config.paths.empty?)
      end
    end

    test "install refuses a clients.d that is a regular file before it writes anything" do
      with_layout do |layout|
        Dir.mkdir_p(layout.paths.config_directory, 0o755)
        File.write(layout.paths.clients_directory, "not a directory")
        recorder = Recorder.new { succeeded }
        load_config = loads(layout)
        outcome = install(checking_installer(layout, recorder: recorder, loads: load_config))

        assert(outcome.status == 1)
        assert(outcome.error == refused_directory(layout.paths.clients_directory, reason: "it is not a directory"))
        assert(!File.exists?(layout.paths.config))
        assert(recorder.calls.empty?)
        assert(load_config.paths.empty?)
      end
    end

    test "install refuses a clients.d that is a symbolic link to a directory" do
      with_layout do |layout|
        target = File.join(layout.directory, "elsewhere")
        Dir.mkdir_p(target, 0o755)
        Dir.mkdir_p(layout.paths.config_directory, 0o755)
        File.symlink(target, layout.paths.clients_directory)
        outcome = install(installer(layout, recorder: Recorder.new { succeeded }))

        assert(outcome.status == 1)
        assert(outcome.error == refused_directory(layout.paths.clients_directory, reason: "it is a symbolic link"))
        assert(!File.exists?(layout.paths.config))
      end
    end

    test "install refuses the existing directory it would create the configuration directory in when others may write it" do
      with_layout do |layout|
        parent = File.dirname(layout.paths.config_directory)
        Dir.mkdir_p(parent, 0o755)
        File.chmod(parent, 0o775)
        recorder = Recorder.new { succeeded }
        load_config = loads(layout)
        outcome = install(checking_installer(layout, recorder: recorder, loads: load_config))

        assert(outcome.status == 1)
        assert(outcome.error == refused_directory(parent, reason: "its mode is 0775"))
        assert(!File.exists?(layout.paths.config_directory))
        assert(recorder.calls.empty?)
        assert(load_config.paths.empty?)
      end
    end

    test "install refuses an existing configuration directory whose parent others may write" do
      with_layout do |layout|
        parent = File.dirname(layout.paths.config_directory)
        Dir.mkdir_p(layout.paths.config_directory, 0o755)
        File.chmod(layout.paths.config_directory, 0o755)
        File.chmod(parent, 0o777)
        recorder = Recorder.new { succeeded }
        load_config = loads(layout)
        outcome = install(checking_installer(layout, recorder: recorder, loads: load_config))

        assert(outcome.status == 1)
        assert(outcome.error == refused_directory(parent, reason: "its mode is 0777"))
        assert(outcome.output.empty?)
        assert(Dir.children(layout.paths.config_directory).empty?)
        assert(recorder.calls.empty?)
        assert(load_config.paths.empty?)
      end
    end

    test "install refuses a configuration directory below a symbolic link" do
      with_layout do |layout|
        target = File.join(layout.directory, "elsewhere")
        Dir.mkdir_p(File.join(target, "tunnelgeist"), 0o755)
        File.symlink(target, File.dirname(layout.paths.config_directory))
        outcome = install(installer(layout, recorder: Recorder.new { succeeded }))

        assert(outcome.status == 1)
        assert(outcome.error == refused_directory(File.dirname(layout.paths.config_directory),
          reason: "it is a symbolic link"))
        assert(Dir.children(File.join(target, "tunnelgeist")).empty?)
      end
    end

    test "install refuses directories owned by someone else, the binary root first" do
      with_layout do |layout|
        Dir.mkdir_p(layout.paths.config_directory, 0o755)
        other = Install::Owner.new(uid: layout.owner.uid + 1, gid: layout.owner.gid)
        installer = Install.new(run: Recorder.new { succeeded }.run, effective_uid: -> { 0_u32 }, paths: layout.paths,
          owner: other, executable: layout.executable, find_group: ->(_name : String) : UInt32? { 20_u32 },
          lint: ->(_xml : String) : String? { nil }, load_config: loads(layout).load)
        outcome = install(installer)

        assert(outcome.status == 1)
        assert(outcome.error == refused_directory(layout.paths.root, reason: "it is owned by uid #{layout.owner.uid}"))
        assert(Dir.children(layout.paths.config_directory).empty?)
      end
    end

    test "install names USER in the group hint without a sudo user" do
      with_layout do |layout|
        outcome = install(installer(layout, recorder: Recorder.new { succeeded }))

        assert(outcome.lines.last == "  sudo #{DSEDITGROUP} -o edit -a USER -t user tunnelgeist")
      end
    end

    test "install creates a missing group with dseditgroup first" do
      with_layout do |layout|
        created = false
        recorder = Recorder.new do |argv|
          created = true if argv.first == DSEDITGROUP
          succeeded
        end
        find_group = ->(_name : String) : UInt32? { created ? 20_u32 : nil }
        outcome = install(installer(layout, recorder: recorder, find_group: find_group), group: "helpers")

        assert(outcome.status == 0)
        assert(recorder.calls.first == [DSEDITGROUP, "-o", "create", "helpers"])
        assert(recorder.calls[1..] == [BOOTOUT, [LAUNCHCTL, "bootstrap", "system", layout.paths.plist]])
        assert(outcome.lines.first == "created group helpers")
      end
    end

    test "install fails when dseditgroup cannot create the group" do
      with_layout do |layout|
        recorder = Recorder.new { failed(64, error: "no rights\n") }
        find_group = ->(_name : String) : UInt32? { nil }
        outcome = install(installer(layout, recorder: recorder, find_group: find_group), group: "helpers")

        assert(outcome.status == 1)
        assert(outcome.error == "tunnelgeist: #{DSEDITGROUP} -o create helpers exited 64: no rights\n")
        assert(recorder.calls.size == 1)
      end
    end

    test "install fails when the group is still missing after dseditgroup created it" do
      with_layout do |layout|
        recorder = Recorder.new { succeeded }
        find_group = ->(_name : String) : UInt32? { nil }
        outcome = install(installer(layout, recorder: recorder, find_group: find_group), group: "helpers")

        assert(outcome.status == 1)
        assert(outcome.lines == ["created group helpers"])
        assert(outcome.error == "tunnelgeist: group helpers not found after creating it\n")
        assert(recorder.calls == [[DSEDITGROUP, "-o", "create", "helpers"]])
      end
    end

    test "install refuses to copy a running executable that is a symbolic link" do
      with_layout do |layout|
        link = File.join(layout.directory, "linked-executable")
        File.symlink(layout.executable, link)
        recorder = Recorder.new { succeeded }
        installer = Install.new(run: recorder.run, effective_uid: -> { 0_u32 }, paths: layout.paths, owner: layout.owner,
          executable: link, find_group: ->(_name : String) : UInt32? { 20_u32 },
          lint: ->(_xml : String) : String? { nil }, load_config: loads(layout).load)
        outcome = install(installer)

        assert(outcome.status == 1)
        assert(outcome.error.starts_with?("tunnelgeist: cannot open the running executable #{link} without following " \
                                          "a symbolic link: "))
        assert(recorder.calls.empty?)
        assert(!File.exists?(layout.paths.binary))
        assert(Dir.children(File.dirname(layout.paths.binary)).empty?)
      end
    end

    test "install fails before it unloads anything when it cannot find the running executable" do
      with_layout do |layout|
        recorder = Recorder.new { succeeded }
        installer = Install.new(run: recorder.run, effective_uid: -> { 0_u32 }, paths: layout.paths, owner: layout.owner,
          executable: nil, find_group: ->(_name : String) : UInt32? { 20_u32 },
          lint: ->(_xml : String) : String? { nil }, load_config: loads(layout).load)
        outcome = install(installer)

        assert(outcome.status == 1)
        assert(outcome.error == "tunnelgeist: cannot find the running executable\n")
        assert(outcome.lines == ["wrote #{layout.paths.config}"])
        assert(recorder.calls.empty?)
        assert(!File.exists?(layout.paths.binary))
        assert(!File.exists?(layout.paths.plist))
      end
    end

    test "install reports a failed bootout as a notice and goes on" do
      with_layout do |layout|
        recorder = Recorder.new { |argv| argv == BOOTOUT ? failed(3, error: "Boot-out failed: 3: No such process\n") : succeeded }
        outcome = install(installer(layout, recorder: recorder))

        assert(outcome.status == 0)
        assert(outcome.lines == [
          "wrote #{layout.paths.config}",
          "installed #{layout.paths.binary}",
          "launchctl bootout exited 3: Boot-out failed: 3: No such process (not loaded?)",
          "wrote #{layout.paths.plist}",
          "loaded io.github.jochenseeber.tunnelgeist; launchd listens on #{layout.socket}",
          "Add a user to the group tunnelgeist with:",
          "  sudo #{DSEDITGROUP} -o edit -a USER -t user tunnelgeist",
        ])
        assert(recorder.calls == [BOOTOUT, [LAUNCHCTL, "bootstrap", "system", layout.paths.plist]])
      end
    end

    test "install fails when launchctl bootstrap fails" do
      with_layout do |layout|
        recorder = Recorder.new { |argv| argv[1] == "bootstrap" ? failed(5, error: "Input/output error\n") : succeeded }
        outcome = install(installer(layout, recorder: recorder))

        assert(outcome.status == 1)
        assert(outcome.error == "tunnelgeist: #{LAUNCHCTL} bootstrap system #{layout.paths.plist} exited 5: Input/output error\n")
      end
    end

    test "install stops before it copies or unloads anything when the plist does not lint" do
      with_layout do |layout|
        recorder = Recorder.new { succeeded }
        lint = ->(_xml : String) : String? { "<stdin>: Unexpected character" }
        outcome = install(installer(layout, recorder: recorder, lint: lint))

        assert(outcome.status == 1)
        assert(outcome.error == "tunnelgeist: the property list does not pass /usr/bin/plutil -lint: <stdin>: Unexpected character\n")
        assert(outcome.lines == ["wrote #{layout.paths.config}"])
        assert(recorder.calls.empty?)
        assert(!File.exists?(layout.paths.binary))
      end
    end

    test "install refuses a binary directory others may write before it changes anything" do
      with_layout do |layout|
        File.chmod(layout.paths.root, 0o775)
        recorder = Recorder.new { succeeded }
        load_config = loads(layout)
        outcome = install(checking_installer(layout, recorder: recorder, loads: load_config))

        assert(outcome.status == 1)
        assert(outcome.error == refused_directory(layout.paths.root, reason: "its mode is 0775"))
        assert(outcome.output.empty?)
        assert(recorder.calls.empty?)
        assert(load_config.paths.empty?)
        assert(!File.exists?(File.dirname(layout.paths.binary)))
        assert(!File.exists?(layout.paths.config_directory))
      end
    end

    test "install refuses a directory below the binary root that others may write" do
      with_layout do |layout|
        Dir.mkdir_p(File.dirname(layout.paths.binary), 0o755)
        File.chmod(File.dirname(layout.paths.binary), 0o777)
        outcome = install(installer(layout, recorder: Recorder.new { succeeded }))

        assert(outcome.status == 1)
        assert(outcome.error == refused_directory(File.dirname(layout.paths.binary), reason: "its mode is 0777"))
        assert(!File.exists?(layout.paths.config))
      end
    end

    test "install creates the binary directory mode 0755 with the owner" do
      with_layout do |layout|
        outcome = with_umask(0o077) { install(installer(layout, recorder: Recorder.new { succeeded })) }
        info = File.info(File.dirname(layout.paths.binary), follow_symlinks: false)

        assert(outcome.status == 0)
        assert(info.permissions.value == 0o755)
        assert(info.owner_id == layout.owner.uid.to_s)
      end
    end
  {% end %}
end
