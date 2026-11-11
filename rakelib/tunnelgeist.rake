# frozen_string_literal: true

require "English"
require "digest"
require "fileutils"
require "json"
require "socket"

# Project-specific tasks of this shard that the rake template does not provide.

desc "Format the Crystal sources and tests (optional argument: check)"
task "format", [:check] do |_task, args|
  command = ["crystal", "tool", "format"]
  command << "--check" if args[:check]
  sh(*command, "src", "spec", "test")
end

# `lint` comes from rakelib/crystal.rake; this adds the spell check and the
# examples to it.
task "lint" => ["lint:spelling", "examples:check"]

namespace "examples" do
  # The example programs, built against the library in src/ the way a program
  # that depends on the shard finds it with `require "tunnelgeist"`.
  programs = FileList["examples/*.cr"]
  environment = -> { {"CRYSTAL_PATH" => "src:#{`crystal env CRYSTAL_PATH`.strip}"} }

  desc "Type-check the example programs against the library"
  task "check" do
    programs.each { |program| sh environment.call, "crystal", "build", "--no-codegen", program }
  end

  desc "Build the example programs into .work/examples/"
  task "build" => "prepare" do
    FileUtils.mkdir_p(".work/examples")
    link = Crystal::PROJECT.combined_linker_args(profile: Crystal::PROJECT.default_profile)
    programs.each do |program|
      output = File.join(".work/examples", File.basename(program, ".cr"))
      sh environment.call, "crystal", "build", program, "-o", output, "--link-flags=#{link}"
    end
  end
end

namespace "lint" do
  desc "Check the spelling of the tracked files with cspell (words in cspell.dict)"
  task "spelling" do
    # Only tracked files: build output, dependencies and agent scratch space
    # are not the project's text. cspell reads the list from stdin, which
    # keeps a long list off the command line.
    files = IO.popen(["git", "ls-files"], &:read)
    abort "lint:spelling cannot list the tracked files" unless $CHILD_STATUS.success?

    command = ["cspell", "--no-progress", "--no-must-find-files", "--file-list", "stdin"]
    command << "--no-color" if no_color?
    IO.popen(command, "w") { |io| io.write(files) }
    abort "lint:spelling found unknown words (fix them or add real terms to cspell.dict)" unless $CHILD_STATUS.success?
  end
end

namespace "homebrew" do
  # The tap the formula is published in.
  HOMEBREW_TAP = "jochenseeber/tap"

  desc "Commit the formula into the local checkout of the tap (HOMEBREW_TAP_DIR, default: brew's checkout); never pushes"
  task "tap" do
    formula = Crystal::PROJECT.formula_path
    version = File.read(formula)[%r{^\s*version\s+"([^"]+)"$}, 1]
    abort "#{formula} has no version line" unless version
    abort "#{formula} still holds placeholder checksums; run rake homebrew:formula:update first" if File.read(formula).include?("0" * 64)

    tap = ENV.fetch("HOMEBREW_TAP_DIR", "")
    if tap.empty?
      tap = IO.popen(["brew", "--repository", HOMEBREW_TAP], &:read).strip
      abort "brew --repository #{HOMEBREW_TAP} failed; tap it first or set HOMEBREW_TAP_DIR" unless $CHILD_STATUS.success?
    end
    abort "#{tap} is not a git checkout of the tap" unless File.directory?(File.join(tap, ".git"))

    target = File.join(tap, "Formula", File.basename(formula))
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(formula, target)
    sh "brew", "style", target
    relative = File.join("Formula", File.basename(formula))
    sh "git", "-C", tap, "add", relative
    # Staged first, because `git diff --quiet` ignores a file the tap does not
    # track yet. Both the check and the commit take the formula only, so
    # other changes staged in the tap are neither committed nor counted.
    if system("git", "-C", tap, "diff", "--cached", "--quiet", "--", relative)
      puts "#{target} is already up to date"
    else
      sh "git", "-C", tap, "commit", "-m", "#{File.basename(formula, ".rb")} #{version}", "--", relative
      puts "Committed #{target}; publish it with: git -C #{tap} push"
    end
  end
end

# The integration tests: Crystal with microtest in test/, where the template's
# `<component>:test` would run RSpec. They are compiled and run like the unit
# specs, with the same linker arguments.
INTEGRATION_TESTS = "test/tunnelgeist/**/*_test.cr"
# The tests that need the root daemon, run only by `test:daemon`.
DAEMON_TESTS = "test/daemon/**/*_test.cr"

# Runs the microtest files matching *glob* as one program; *pattern* is passed
# on as `--example`, as `<component>:spec` does.
def crystal_tests(glob, pattern: nil)
  project = Crystal::PROJECT
  component = project.components.find { |candidate| candidate.name == "tunnelgeist" }
  link = project.combined_linker_args(profile: project.default_profile, component: component)
  command = ["crystal", "spec", *Dir[glob].sort, "-Dspec", "--link-flags=#{link}"]
  command += ["--example", pattern] if pattern
  sh(*command)
end

Rake::Task["tunnelgeist:test"].clear
Rake::Task["test"].clear

namespace "tunnelgeist" do
  desc "Run the integration tests for tunnelgeist except the daemon tests (optional argument: example pattern)"
  task "test", [:pattern] => "prepare" do |_task, args|
    crystal_tests(INTEGRATION_TESTS, pattern: args[:pattern])
    puts "The tests that need the root daemon run with: rake test:daemon"
  end
end

# Invokes the component's task rather than depending on it, because a Rake
# prerequisite cannot be passed an argument.
desc "Run the integration tests except the daemon tests (optional argument: example pattern)"
task "test", [:pattern] do |_task, args|
  Rake::Task["tunnelgeist:test"].invoke(args[:pattern])
end

namespace "test" do
  desc "Run the tests of the tunnelgeist daemon (TUNNELGEIST_SOCKET); starts the daemon under sudo and runs the tests as you"
  task "daemon" => "prepare" do
    abort "test:daemon needs macOS" unless RUBY_PLATFORM.include?("darwin")

    project = Crystal::PROJECT
    link = project.combined_linker_args(profile: project.default_profile)
    FileUtils.mkdir_p(".work")
    daemon = File.join(".work", "tunnelgeist")
    socket = File.expand_path(File.join(".work", "tunnelgeist.sock"))
    # The daemon runs as root and reads only a configuration that root owns,
    # through directories that root owns and no one else may write, from `/`
    # down. A home directory belongs to its user, so the file is written here
    # as the user and installed with sudo into a directory of its own in
    # root's home, named by its `/private` path: `/var` is a symbolic link,
    # which the daemon refuses. The name carries a digest of the checkout's
    # real path, so the runs of two checkouts do not overwrite or remove
    # each other's configuration.
    checkout = Digest::SHA256.hexdigest(File.realpath(Dir.pwd))[0, 8]
    config_directory = "/private/var/root/tunnelgeist-daemon-test-#{checkout}"
    config = File.join(config_directory, "config.json")
    config_made = false
    staged_config = File.join(".work", "root-config.json")
    binary = File.join(".work", "daemon-tests")
    group = `id -gn`.strip
    abort "test:daemon cannot tell your primary group" if group.empty?

    sh "crystal", "build", "src/bin/tunnelgeist.cr", "-o", daemon, "--link-flags=#{link}"
    sh "crystal", "build", *Dir[DAEMON_TESTS].sort, "-o", binary, "-Dspec", "--link-flags=#{link}"

    # Ask for the password here, in the foreground, so neither the background
    # daemon nor the `sudo kill` below stops at a prompt.
    sh "sudo", "-v"
    begin
      # The tests' networks, not just their addresses: 10.77.0.0/16 holds
      # their address 10.77.3.1/24 and its peer 10.77.3.2, and the routes they
      # add lie in 10.78.0.0/16 and 10.79.0.0/16. Anything outside is refused.
      File.write(staged_config, JSON.pretty_generate(
        "socket" => socket,
        "group" => group,
        "clients" => [
          {
            "name" => "daemon-test",
            "addresses" => [{ "network" => "10.77.0.0/16", "peer" => "10.77.0.0/16" }],
            "routes" => ["10.78.0.0/16", "10.79.0.0/16"],
          },
        ],
      ))
      config_made = true
      sh "sudo", "install", "-d", "-o", "root", "-g", "wheel", "-m", "0755", config_directory
      sh "sudo", "install", "-o", "root", "-g", "wheel", "-m", "0644", staged_config, config
      FileUtils.rm_f(socket)
      daemon_pid = nil
      pid = Process.spawn("sudo", File.expand_path(daemon), "serve", "--config", config)
      # The daemon's own pid, found by its command line, which names the unique
      # configuration path; nil while it is not running. sudo may run the
      # command under a monitor process (use_pty), so the child of `pid` can be
      # that monitor rather than the daemon. The pattern is anchored at the
      # daemon's path, so sudo's own command lines, which start with "sudo",
      # never match.
      find_daemon = lambda do
        ere = ->(text) { text.gsub(/[.\[\]()*+?{}|^$\\]/) { |char| "\\#{char}" } }
        pattern = "^#{ere.call(File.expand_path(daemon))} serve --config #{ere.call(config)}( |$)"
        IO.popen(["pgrep", "-f", pattern], &:read).split.first&.to_i
      end
      # Reaps the daemon's sudo without blocking; true once it has exited.
      exited = lambda do
        Process.waitpid(pid, Process::WNOHANG) ? true : false
      rescue Errno::ECHILD
        true
      end
      begin
        deadline = Time.now + 10
        ready = false
        until ready
          abort "tunnelgeist exited before it was ready" if exited.call
          begin
            UNIXSocket.new(socket).close
            ready = true
          rescue SystemCallError
            abort "tunnelgeist did not accept connections on #{socket} within 10 s" if Time.now > deadline
            sleep 0.1
          end
        end

        # The probe connection sends nothing and closes at once; the daemon's
        # handler reads end of input, has no request to answer and closes too.
        # sudo cannot relay SIGKILL, so the stop path needs the daemon's own
        # pid, resolved as soon as the daemon accepts.
        daemon_pid = find_daemon.call

        # The socket tells the tests where the daemon listens.
        sh({ "TUNNELGEIST_SOCKET" => socket }, File.expand_path(binary))
      ensure
        # Renew sudo's timestamp: a long test run may have let it expire, and
        # the kills below must not stop at a prompt.
        system("sudo", "-v")
        # An abort before the socket accepted leaves the pid unknown.
        daemon_pid ||= find_daemon.call
        target = daemon_pid || pid
        # A TERM to the daemon makes it close its devices and remove its socket.
        system("sudo", "kill", "-TERM", target.to_s)
        stop_deadline = Time.now + 5
        sleep 0.1 until exited.call || Time.now > stop_deadline
        unless exited.call
          # sudo cannot relay SIGKILL, so the daemon is killed itself and sudo
          # then follows it.
          system("sudo", "kill", "-KILL", target.to_s)
          reap_deadline = Time.now + 5
          sleep 0.1 until exited.call || Time.now > reap_deadline
          warn "tunnelgeist (pid #{target}) may still be running" unless exited.call
        end
      end
    ensure
      # Root owns the configuration, so sudo removes it, also when writing it
      # or starting the daemon failed. Only root may look into its home, so
      # the directory counts as there once the task set out to make it.
      FileUtils.rm_f(staged_config)
      if config_made
        # A failed removal leaves a file root owns behind, so it is said.
        warn "test:daemon could not remove #{config}; remove it with sudo" unless system("sudo", "rm", "-f", config)
        unless system("sudo", "rmdir", config_directory)
          warn "test:daemon could not remove #{config_directory}; remove it with sudo"
        end
      end
    end
  end
end
