require "json"
require "../spec_helper"
require "../../src/tunnelgeist/cli"
require "./support/temporary_directory"

# The command line of `tunnelgeist` (UA5, UA9). Only the paths that change
# nothing on the system and read nothing of it run here, with files and
# sockets in a temporary directory; the rest are integration tests.
describe TunnelgeistCLI do
  {% if flag?(:darwin) %}
    include TunnelgeistTemporaryDirectory

    alias Command = Tunnelgeist::CLI::Command

    record Result, status : Int32, output : String, error : String

    def run(*args : String, sudo_user : String? = nil) : Result
      run_list(args.to_a, sudo_user: sudo_user)
    end

    def run_list(args : Array(String), *, sudo_user : String? = nil) : Result
      output = IO::Memory.new
      error = IO::Memory.new
      status = Tunnelgeist::CLI.run(args, output: output, error: error, sudo_user: sudo_user)
      Result.new(status: status, output: output.to_s, error: error.to_s)
    end

    # Whether a connect to *path* succeeds.
    def listening?(path : String) : Bool
      UNIXSocket.new(path).close
      true
    rescue Socket::ConnectError
      false
    end

    # Writes a configuration with *socket*, *group* and one client that
    # restricts nothing to `config.json` in *directory*, mode 0644, and
    # returns its path.
    def write_config(directory : String, *, socket : String, group : String) : String
      content = JSON.build do |json|
        json.object do
          json.field "socket", socket
          json.field "group", group
          json.field "clients" do
            json.array do
              json.object { json.field "name", "default" }
            end
          end
        end
      end
      path = File.join(directory, "config.json")
      File.write(path, content)
      File.chmod(path, 0o644)
      path
    end

    # `F_DUPFD` of fcntl.h, which the standard library does not declare.
    F_DUPFD = 0

    # A second descriptor for the open file of *fd*.
    def duplicate(fd : Int32) : Int32
      copy = LibC.fcntl(fd, F_DUPFD, 0)
      raise IO::Error.from_errno("fcntl(F_DUPFD)") if copy == -1
      copy
    end

    # A socket file at *path* that nothing listens on.
    def stale_socket(path : String) : Nil
      socket = Socket.unix
      socket.bind(Socket::UNIXAddress.new(path))
      socket.close
    end

    test "help prints the commands" do
      result = run("help")

      assert(result.status == 0)
      assert(result.output.includes?("serve"))
      assert(result.output.includes?("install"))
      assert(result.output.includes?("uninstall"))
    end

    test "Command.from_argument? matches the command words and the help flags exactly" do
      assert(Command.from_argument?("serve") == Command::Serve)
      assert(Command.from_argument?("install") == Command::Install)
      assert(Command.from_argument?("uninstall") == Command::Uninstall)
      assert(Command.from_argument?("help") == Command::Help)
      assert(Command.from_argument?("-h") == Command::Help)
      assert(Command.from_argument?("--help") == Command::Help)
      assert(Command.from_argument?("Serve").nil?)
      assert(Command.from_argument?("UNINSTALL").nil?)
      assert(Command.from_argument?("").nil?)
    end

    test "every command is found by its word" do
      Command.each do |command|
        assert(Command.from_argument?(command.word) == command)
      end
    end

    test "the help flags and no command print the commands" do
      assert(run("-h").output.includes?("Commands:"))
      assert(run("--help").output.includes?("Commands:"))
      assert(Tunnelgeist::CLI.run([] of String, output: IO::Memory.new, error: IO::Memory.new) == 0)
    end

    test "version takes no options" do
      assert(run("version", "--bogus").status == 2)
      assert(run("version", "--help").output.starts_with?("Usage: tunnelgeist version"))
    end

    test "each command prints its help text" do
      flag = "    -h, --help                       Show this help"
      config = "        --config PATH                The configuration file (default /usr/local/etc/tunnelgeist/config.json)"
      group = "        --group GROUP                The group of a new starter configuration, created if missing (default tunnelgeist)"
      {
        "serve"     => ["Usage: tunnelgeist serve [--config PATH]", config, flag],
        "install"   => ["Usage: tunnelgeist install [--group GROUP] [--config PATH]", group, config, flag],
        "uninstall" => ["Usage: tunnelgeist uninstall", flag],
        "version"   => ["Usage: tunnelgeist version", flag],
      }.each do |command, lines|
        expected = Result.new(status: 0, output: lines.join('\n') + "\n", error: "")

        assert(run(command, "--help") == expected)
        assert(run(command, "-h") == expected)
      end
    end

    test "Options.parse reads a value after = and takes the next argument as the value whatever it is" do
      joined = Tunnelgeist::CLI::Options.parse(command: Command::Install, args: ["--config=a=b", "--group=staff"])
      empty = Tunnelgeist::CLI::Options.parse(command: Command::Serve, args: ["--config="])
      dashed = Tunnelgeist::CLI::Options.parse(command: Command::Serve, args: ["--config", "--help"])
      last = Tunnelgeist::CLI::Options.parse(command: Command::Serve, args: ["--config", "a", "--config", "b"])

      assert(joined.config == "a=b")
      assert(joined.group == "staff")
      assert(empty.config == "")
      assert(dashed.config == "--help")
      assert(!dashed.help?)
      assert(last.config == "b")
    end

    test "a flag without its value is a usage error naming it" do
      [["serve", "--config"], ["install", "--group"], ["install", "-h", "--group"]].each do |args|
        result = run_list(args)

        assert(result.status == 2)
        assert(result.error == "tunnelgeist: Missing option: #{args.last}\nRun 'tunnelgeist #{args.first} --help' for the options.\n")
      end
    end

    test "an option the command does not take is a usage error quoting it whole" do
      ["--bogus", "-x", "-hx", "-h=x", "--help=yes", "--conf", "---config", "--=x", "-=x"].each do |option|
        result = run("serve", option)

        assert(result.status == 2)
        assert(result.error == "tunnelgeist: Invalid option: #{option}\nRun 'tunnelgeist serve --help' for the options.\n")
      end
      assert(run("serve", "extra", "--bogus").error.starts_with?("tunnelgeist: Invalid option: --bogus\n"))
      assert(run("serve", "--help", "--bogus").error.starts_with?("tunnelgeist: Invalid option: --bogus\n"))
    end

    test "an argument that is no option is a usage error unless the help is asked for" do
      [["extra"], ["-"], [""], ["--", "extra"], ["--", "--config"], ["--config", "c", "extra"]].each do |args|
        result = run_list(["serve"] + args)

        assert(result.status == 2)
        assert(result.error ==
               "tunnelgeist: Unexpected argument #{args.last.inspect}\nRun 'tunnelgeist serve --help' for the options.\n")
      end
      assert(run("serve", "--help", "extra").output.starts_with?("Usage: tunnelgeist serve"))
      assert(run("serve", "extra", "-h").output.starts_with?("Usage: tunnelgeist serve"))
      assert(Tunnelgeist::CLI::Options.parse(command: Command::Serve, args: ["--"]).config == Tunnelgeist::Config::DEFAULT_PATH)
    end

    test "a command word in another case is an unknown command" do
      result = run("Serve")

      assert(result.status == 2)
      assert(result.error.includes?("unknown command \"Serve\""))
    end

    test "Options.parse reads serve --config and keeps the help text of the command in usage" do
      options = Tunnelgeist::CLI::Options.parse(command: Command::Serve, args: ["--config", "/tmp/tg.json"])

      assert(options.config == "/tmp/tg.json")
      assert(options.usage.starts_with?("Usage: tunnelgeist serve [--config PATH]\n"))
      assert(options.usage.includes?("--config PATH"))
    end

    test "Options.parse reads install --group and --config" do
      options = Tunnelgeist::CLI::Options.parse(command: Command::Install, args: ["--group", "staff", "--config", "x"])

      assert(options.group == "staff")
      assert(options.config == "x")
      assert(options.usage.starts_with?("Usage: tunnelgeist install [--group GROUP] [--config PATH]\n"))
    end

    test "install --help says --group names the group of a new starter configuration" do
      options = Tunnelgeist::CLI::Options.parse(command: Command::Install, args: ["--help"])

      assert(options.usage.includes?(
        "The group of a new starter configuration, created if missing (default tunnelgeist)"))
    end

    test "Options default to the default configuration path and group" do
      serve = Tunnelgeist::CLI::Options.parse(command: Command::Serve, args: [] of String)
      install = Tunnelgeist::CLI::Options.parse(command: Command::Install, args: [] of String)

      assert(Tunnelgeist::Config::DEFAULT_PATH == "/usr/local/etc/tunnelgeist/config.json")
      assert(serve.config == Tunnelgeist::Config::DEFAULT_PATH)
      assert(install.config == Tunnelgeist::Config::DEFAULT_PATH)
      assert(install.group == "tunnelgeist")
    end

    test "an unknown command is a usage error" do
      result = run("start")

      assert(result.status == 2)
      assert(result.error.includes?("unknown command \"start\""))
    end

    test "serve with a configuration file that does not exist fails with the error" do
      with_temporary_directory do |directory|
        path = File.join(directory, "config.json")
        result = run("serve", "--config", path)

        assert(result.status == 1)
        assert(result.error == "tunnelgeist: #{path}: does not exist\n")
        assert(result.output.empty?)
      end
    end

    test "serve with an unknown option or an extra argument is a usage error" do
      assert(run("serve", "--config", "c", "--bogus").status == 2)
      assert(run("serve", "--config", "c", "extra").status == 2)
    end

    test "the removed serve options --group, --require and --socket are usage errors" do
      {"--group" => "g", "--require" => "anchor apple", "--socket" => "/tmp/s"}.each do |option, value|
        result = run("serve", option, value)

        assert(result.status == 2)
        assert(result.error == "tunnelgeist: Invalid option: #{option}\nRun 'tunnelgeist serve --help' for the options.\n")
      end
    end

    test "install --require is a usage error" do
      result = run("install", "--require", "anchor apple")

      assert(result.status == 2)
      assert(result.error.starts_with?("tunnelgeist: Invalid option: --require\n"))
    end

    test "install with an extra argument is a usage error" do
      assert(run("install", "extra").status == 2)
      assert(run("uninstall", "--group", "g").status == 2)
    end

    test "a group name starting with a dash is a usage error" do
      joined = run("install", "--group=-x")
      separate = run("install", "--group", "-o")

      assert(joined.status == 2)
      assert(joined.error.includes?("--group must be a group name, got \"-x\""))
      assert(separate.status == 2)
      assert(separate.error.includes?("--group must be a group name, got \"-o\""))
    end

    test "serve with a configured socket path too long to bind fails at start as a configuration error" do
      with_temporary_directory do |directory|
        path = File.join(directory, "s" * 120 + ".sock")
        # The socket is checked before the group, which no lookup reaches.
        config = write_config(directory, socket: path, group: "tg")
        result = run("serve", "--config", config)

        assert(result.status == 1)
        assert(result.error == "tunnelgeist: #{config}: field socket: Path size exceeds the maximum size of 103 bytes\n")
        assert(!result.error.includes?("--help"))
      end
    end

    test "SocketPath.clear deletes a socket file nothing listens on" do
      with_temporary_directory do |directory|
        path = socket_path(directory, name: "stale")
        stale_socket(path)
        assert(File.info(path, follow_symlinks: false).type.socket?)

        Tunnelgeist::CLI::SocketPath.clear(path)

        assert(!File.exists?(path))
      end
    end

    test "SocketPath.clear refuses a socket something listens on and leaves it" do
      with_temporary_directory do |directory|
        path = socket_path(directory, name: "busy")
        server = UNIXServer.new(path)
        begin
          error = raised(File::AlreadyExistsError) { Tunnelgeist::CLI::SocketPath.clear(path) }

          assert(error.message == "#{path} is a socket something listens on")
          assert(error.file == path)
          assert(listening?(path))
        ensure
          server.close
        end
      end
    end

    test "SocketPath.clear refuses a file that is not a socket and leaves it" do
      with_temporary_directory do |directory|
        path = socket_path(directory, name: "file")
        File.write(path, "kept")

        error = raised(File::AlreadyExistsError) { Tunnelgeist::CLI::SocketPath.clear(path) }

        assert(error.message == "#{path} exists and is not a socket")
        assert(File.read(path) == "kept")
      end
    end

    test "SocketPath.bound reads the path from the kernel, also for a socket made from a descriptor as launchd passes one" do
      with_temporary_directory do |directory|
        path = socket_path(directory, name: "bound")
        server = UNIXServer.new(path)
        passed = UNIXServer.new(fd: duplicate(server.fd))
        begin
          assert(passed.local_address.path.empty?)
          assert(Tunnelgeist::CLI::SocketPath.bound(passed) == path)
          assert(Tunnelgeist::CLI::SocketPath.bound(server) == path)
        ensure
          passed.close
          server.close
        end
      end
    end

    test "SocketPath.bound refuses a socket without a path" do
      unbound = Socket.unix
      passed = UNIXServer.new(fd: duplicate(unbound.fd))
      begin
        error = raised(Socket::Error) { Tunnelgeist::CLI::SocketPath.bound(passed) }

        assert(error.message == "listening socket has no path")
      ensure
        passed.close
        unbound.close
      end
    end

    test "SocketPath.clear does nothing when nothing is at the path" do
      with_temporary_directory do |directory|
        path = socket_path(directory, name: "absent")

        Tunnelgeist::CLI::SocketPath.clear(path)

        assert(!File.exists?(path))
      end
    end
  {% end %}
end
