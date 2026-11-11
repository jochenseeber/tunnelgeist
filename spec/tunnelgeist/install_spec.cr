require "../spec_helper"
require "file_utils"
require "json"
require "../../src/tunnelgeist/install"
require "../../src/tunnelgeist/install/starter"
require "./support/fake_membership"
require "./support/temporary_directory"

# The LaunchDaemon property list `install` writes (UA9, UB1), its starter
# configuration and paths, the refusal of `install` and `uninstall` as
# non-root, and `uninstall` against a temporary directory with a recording
# runner. `install` as root walks the real directories from `/` down to the
# ones it writes in, so it is an integration test, as are `plutil` and the
# real configuration loader.
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

    LAUNCHCTL = "/bin/launchctl"
    BOOTOUT   = [LAUNCHCTL, "bootout", "system/io.github.jochenseeber.tunnelgeist"]

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

    def timed_out : Tunnelgeist::CommandRunner::Result
      Tunnelgeist::CommandRunner::Result.new(exit_status: -1, output: "", error: "", timed_out_after: 10.seconds)
    end

    # The outcome of one `install` or `uninstall`.
    record Outcome, status : Int32, output : String, error : String do
      def lines : Array(String)
        output.lines
      end
    end

    # A temporary installation layout: a fresh temporary directory with mode
    # 0755, `usr` with mode 0755 below it, the binary one missing directory
    # below that, the property list in a directory of its own, the
    # configuration two missing directories down, the socket the
    # configuration names, and a file standing in for the running
    # executable.
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
          config: File.join(@directory, "etc", "tunnelgeist", "config.json"), log: File.join(@directory, "t.log"))
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

    def uninstall(installer : Install) : Outcome
      output = IO::Memory.new
      error = IO::Memory.new
      status = installer.uninstall(output: output, error: error)
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

    test "plist names the label, the program, the socket and the log" do
      top = top_dict(default_plist)
      listeners = entries(entries(top["Sockets"])["Listeners"])

      assert(top["Label"].content == "io.github.jochenseeber.tunnelgeist")
      assert(listeners["SockPathName"].content == "/var/run/tunnelgeist.sock")
      assert(listeners["SockPathMode"].name == "integer")
      assert(listeners["SockPathMode"].content == "432")
      assert(listeners["SockPathOwner"].content == "0")
      assert(listeners["SockPathGroup"].content == "20")
      assert(top["StandardErrorPath"].content == "/var/log/tunnelgeist.log")
    end

    test "plist starts the daemon with serve --config and the default configuration path" do
      top = top_dict(default_plist)

      assert(strings(top["ProgramArguments"]) == [
        "/usr/local/libexec/tunnelgeist", "serve", "--config", "/usr/local/etc/tunnelgeist/config.json",
      ])
    end

    test "plist takes the configuration path, the socket and the gid it is given" do
      xml = Install.new.plist(config_path: "/etc/tg/main.json", socket: "/var/run/other.sock", group_gid: 501_u32)
      top = top_dict(xml)
      listeners = entries(entries(top["Sockets"])["Listeners"])

      assert(strings(top["ProgramArguments"])[1..] == ["serve", "--config", "/etc/tg/main.json"])
      assert(listeners["SockPathName"].content == "/var/run/other.sock")
      assert(listeners["SockPathGroup"].content == "501")
    end

    test "plist puts each element on its own indented line" do
      xml = default_plist

      assert(xml.includes?("<dict>\n    <key>Label</key>\n"))
    end

    test "plist keeps the XML special characters of a path" do
      binary = "/opt/a & b <x>/tunnelgeist"
      paths = Install::Paths.new(binary: binary, plist: "/tmp/tg.plist", config: "/tmp/tg.json", log: "/tmp/tg.log")
      xml = Install.new(paths: paths).plist(config_path: "/tmp/a & b.json", socket: "/tmp/<tg>.sock", group_gid: 20_u32)
      listeners = entries(entries(top_dict(xml)["Sockets"])["Listeners"])

      assert(strings(top_dict(xml)["ProgramArguments"]) == [binary, "serve", "--config", "/tmp/a & b.json"])
      assert(listeners["SockPathName"].content == "/tmp/<tg>.sock")
    end

    test "Failure carries the program and its exit status when a program failed" do
      failure = Install::Failure.new("launchctl bootstrap exited 5: no", program: "/bin/launchctl", exit_status: 5)

      assert(failure.message == "launchctl bootstrap exited 5: no")
      assert(failure.program == "/bin/launchctl")
      assert(failure.program! == "/bin/launchctl")
      assert(failure.exit_status == 5)
      assert(failure.exit_status! == 5)
    end

    test "Failure carries the time limit of a program that ran out of time" do
      failure = Install::Failure.new("/bin/launchctl bootstrap timed out after 10 s", program: "/bin/launchctl",
        exit_status: -1, timed_out_after: 10.seconds)

      assert(failure.timed_out_after == 10.seconds)
      assert(failure.timed_out_after! == 10.seconds)
    end

    test "Failure has no time limit for a program that ended by itself" do
      failure = Install::Failure.new("launchctl bootstrap exited 5: no", program: "/bin/launchctl", exit_status: 5)

      assert(failure.timed_out_after.nil?)
      assert(raised(NilAssertionError) { failure.timed_out_after! }.message == "no program ran out of time: launchctl bootstrap exited 5: no")
    end

    test "Failure has no program or exit status for a step that ran none" do
      failure = Install::Failure.new("cannot find the running executable")

      assert(failure.program.nil?)
      assert(failure.exit_status.nil?)
      assert(raised(NilAssertionError) { failure.program! }.message.to_s.includes?("cannot find"))
      assert(raised(NilAssertionError) { failure.exit_status! }.message.to_s.includes?("cannot find"))
    end

    test "install as non-root is refused before it runs or writes anything" do
      with_layout do |layout|
        recorder = Recorder.new { succeeded }
        outcome = install(installer(layout, recorder: recorder, uid: 501_u32))

        assert(outcome.status == 1)
        assert(outcome.error == "tunnelgeist: install must run as root\n")
        assert(outcome.output.empty?)
        assert(recorder.calls.empty?)
        assert(!File.exists?(layout.paths.binary))
      end
    end

    test "uninstall as non-root is refused before it runs or removes anything" do
      with_layout do |layout|
        File.write(layout.paths.plist, "kept")
        recorder = Recorder.new { succeeded }
        outcome = uninstall(installer(layout, recorder: recorder, uid: 501_u32))

        assert(outcome.status == 1)
        assert(outcome.error == "tunnelgeist: uninstall must run as root\n")
        assert(recorder.calls.empty?)
        assert(File.exists?(layout.paths.plist))
      end
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

    test "Starter.json is CF6 with the group it is given, laid out by JSON.build" do
      json = Install::Starter.json(socket: "/var/run/tunnelgeist.sock", group: "helpers")

      assert(json == starter_text("helpers"))
      assert(JSON.parse(json) == JSON.parse(CF6.sub(%("group": "tunnelgeist"), %("group": "helpers"))))
    end

    test "Starter.json is CF6 for the default group" do
      json = Install::Starter.json(socket: "/var/run/tunnelgeist.sock", group: "tunnelgeist")

      assert(JSON.parse(json) == JSON.parse(CF6))
    end

    test "Starter.json escapes what JSON must escape" do
      json = Install::Starter.json(socket: %(/tmp/"q".sock), group: "a\\b")

      assert(JSON.parse(json)["socket"] == %(/tmp/"q".sock))
      assert(JSON.parse(json)["group"] == "a\\b")
    end

    test "uninstall unloads the daemon and removes the plist and the binary" do
      with_layout do |layout|
        Dir.mkdir_p(File.dirname(layout.paths.binary))
        File.write(layout.paths.binary, "the daemon")
        File.write(layout.paths.plist, "the plist")
        recorder = Recorder.new { failed(3, error: "Boot-out failed\n") }
        outcome = uninstall(installer(layout, recorder: recorder))

        assert(outcome.status == 0)
        assert(recorder.calls == [BOOTOUT])
        assert(outcome.lines == [
          "launchctl bootout exited 3: Boot-out failed (not loaded?)",
          "removed #{layout.paths.plist}",
          "removed #{layout.paths.binary}",
        ])
        assert(!File.exists?(layout.paths.plist))
        assert(!File.exists?(layout.paths.binary))
      end
    end

    test "uninstall reports a launchctl bootout that ran out of time without guessing why" do
      with_layout do |layout|
        recorder = Recorder.new { timed_out }
        outcome = uninstall(installer(layout, recorder: recorder))

        assert(outcome.status == 0)
        assert(outcome.lines.first == "launchctl bootout timed out after 10 s")
      end
    end

    test "uninstall leaves the configuration directory and says so" do
      with_layout do |layout|
        Dir.mkdir_p(layout.paths.config_directory)
        File.write(layout.paths.config, "the operator's configuration")
        File.write(layout.paths.plist, "the plist")
        outcome = uninstall(installer(layout, recorder: Recorder.new { succeeded }))

        assert(outcome.status == 0)
        assert(outcome.lines == ["removed #{layout.paths.plist}", "left #{layout.paths.config_directory}"])
        assert(File.read(layout.paths.config) == "the operator's configuration")
      end
    end

    test "Paths.default puts the configuration at Config::DEFAULT_PATH unless given another one" do
      paths = Install::Paths.default
      other = Install::Paths.default(config: "/etc/tg/main.json")

      assert(paths.config == "/usr/local/etc/tunnelgeist/config.json")
      assert(paths.config_directory == "/usr/local/etc/tunnelgeist")
      assert(paths.clients_directory == "/usr/local/etc/tunnelgeist/clients.d")
      assert(other.config == "/etc/tg/main.json")
      assert(other.config_directory == "/etc/tg")
      assert(other.clients_directory == "/etc/tg/clients.d")
      assert(other.binary == paths.binary)
      assert(other.plist == paths.plist)
    end

    test "Paths.default makes a relative configuration path absolute" do
      paths = Install::Paths.default(config: "etc/../tg/main.json")

      assert(paths.config == File.join(Dir.current, "tg", "main.json"))
    end
  {% end %}
end
