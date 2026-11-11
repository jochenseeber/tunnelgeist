require "json"
require "../test_helper"
require "../../src/tunnelgeist/cli"
require "../../src/tunnelgeist/lib_system"
require "./support/temporary_directory"

# The command line of `tunnelgeist` (UA5, UA9) where it reads the system:
# the default configuration path, the system's groups, the root-ness of the
# process and the repository's commit through `git`.
describe TunnelgeistCLI do
  {% if flag?(:darwin) %}
    include TunnelgeistTemporaryDirectory

    alias Command = Tunnelgeist::CLI::Command

    record Result, status : Int32, output : String, error : String

    def run(*args : String, sudo_user : String? = nil) : Result
      output = IO::Memory.new
      error = IO::Memory.new
      status = Tunnelgeist::CLI.run(args.to_a, output: output, error: error, sudo_user: sudo_user)
      Result.new(status: status, output: output.to_s, error: error.to_s)
    end

    def root? : Bool
      Tunnelgeist::LibSystem.geteuid == 0
    end

    # The name of the effective group of the process, which `serve` accepts.
    def own_group : String
      System::Group.find_by(id: Tunnelgeist::LibSystem.getegid.to_s).name
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

    # A socket file at *path* that nothing listens on.
    def stale_socket(path : String) : Nil
      socket = Socket.unix
      socket.bind(Socket::UNIXAddress.new(path))
      socket.close
    end

    test "version prints the version and the abbreviated commit" do
      commit = `git rev-parse --short HEAD`.strip
      expected = "tunnelgeist #{Tunnelgeist::VERSION} (#{commit})\n"

      assert(!commit.empty?)
      assert(run("version") == Result.new(status: 0, output: expected, error: ""))
      assert(run("--version").output == expected)
      assert(Command.from_argument?("--version") == Command::Version)
    end

    test "serve without --config loads the default path and fails naming it when it is absent" do
      skip("the default configuration exists") if File.exists?(Tunnelgeist::Config::DEFAULT_PATH)
      result = run("serve")

      assert(result.status == 1)
      assert(result.error == "tunnelgeist: #{Tunnelgeist::Config::DEFAULT_PATH}: does not exist\n")
    end

    test "serve with an unknown group in the configuration fails with the error" do
      with_temporary_directory do |directory|
        group = "tunnelgeist-no-such-group-#{Process.pid}"
        path = write_config(directory, socket: socket_path(directory, name: "nogroup"), group: group)
        result = run("serve", "--config", path)

        assert(result.status == 1)
        assert(result.error == "tunnelgeist: #{path}: field group: unknown group #{group}\n")
      end
    end

    test "install as non-root is refused" do
      skip("runs as root") if root?
      result = run("install")

      assert(result.status == 1)
      assert(result.error.includes?("install must run as root"))
    end

    test "install as non-root is refused with a sudo user given" do
      skip("runs as root") if root?
      result = run("install", sudo_user: "someone")

      assert(result.status == 1)
      assert(result.error.includes?("install must run as root"))
      assert(result.output.empty?)
    end

    test "uninstall as non-root is refused" do
      skip("runs as root") if root?
      result = run("uninstall")

      assert(result.status == 1)
      assert(result.error.includes?("uninstall must run as root"))
    end

    test "serve outside launchd binds the configured socket and refuses one something listens on, leaving it" do
      with_temporary_directory do |directory|
        path = socket_path(directory, name: "live")
        server = UNIXServer.new(path)
        begin
          result = run("serve", "--config", write_config(directory, socket: path, group: own_group))

          assert(result.status == 1)
          assert(result.error.includes?("no listening socket: #{path} is a socket something listens on"))
          assert(listening?(path))
        ensure
          server.close
        end
      end
    end

    test "SocketPath.clear names the path when the connect fails otherwise" do
      skip("runs as root") if root?
      with_temporary_directory do |directory|
        path = socket_path(directory, name: "denied")
        stale_socket(path)
        File.chmod(path, 0o000)

        error = raised(Socket::ConnectError) { Tunnelgeist::CLI::SocketPath.clear(path) }

        assert(error.message == "connect (#{path}): Permission denied")
        assert(error.os_error == Errno::EACCES)
        assert(File.info(path, follow_symlinks: false).type.socket?)
      end
    end
  {% end %}
end
