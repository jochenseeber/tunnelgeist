{% skip_file unless flag?(:darwin) %}

require "random/secure"
require "system/group"
require "xml"
require "./command_runner"
require "./config"
require "./config/error"
require "./install/failure"
require "./install/owner"
require "./install/paths"
require "./install/starter"
require "./lib_system"
require "./protocol/common"

module Tunnelgeist
  # `tunnelgeist install` and `uninstall` (UA9, UC3): put the daemon at a
  # root-owned path and load it as a LaunchDaemon with socket activation,
  # or take it away again. Every collaborator that reaches the system is
  # given to the constructor, with the real one as its default.
  class Install
    # The launchd label of the daemon, and the name of its property list.
    LABEL = "io.github.jochenseeber.tunnelgeist"
    # The group whose members may use the daemon unless `--group` says
    # otherwise.
    DEFAULT_GROUP = "tunnelgeist"
    # 0660: read and write for root and the group (UA8).
    SOCKET_MODE = 0o660

    # The program that loads and unloads the daemon.
    LAUNCHCTL = "/bin/launchctl"
    # The program that creates the group.
    DSEDITGROUP = "/usr/sbin/dseditgroup"
    # The program that checks the property list.
    PLUTIL = "/usr/bin/plutil"

    # *run* runs `launchctl` and `dseditgroup`; *effective_uid* tells
    # whether the process runs as root; *paths* and *owner* say where the
    # files go and whose they are; *executable* is the binary `install`
    # copies, nil when it cannot be found; *find_group* returns the gid of
    # a group name, nil for an unknown one; *lint* checks the property list
    # as `Install.lint` does; *load_config* loads the configuration whose
    # main file it is given, raising `Config::Error` as `Config.load` does.
    def initialize(*, @run : CommandRunner::Run = CommandRunner.default,
                   @effective_uid : -> UInt32 = -> { LibSystem.geteuid },
                   @paths : Paths = Paths.default, @owner : Owner = Owner.root,
                   @executable : String? = Process.executable_path,
                   @find_group : String -> UInt32? = ->(name : String) : UInt32? { System::Group.find_by?(name: name).try(&.id.to_u32) },
                   @lint : String -> String? = ->(xml : String) : String? { Install.lint(xml) },
                   @load_config : String -> Config = ->(path : String) { Config.load(path) })
    end

    # The LaunchDaemon property list (UA9): the label, the program and its
    # arguments, the socket launchd listens on for the daemon, and the log.
    # The program is `serve --config` *config_path*, which it reads
    # everything else from (CA7); launchd creates *socket* for it, owned by
    # root and the numeric *group_gid* (UB1).
    def plist(*, config_path : String, socket : String, group_gid : UInt32) : String
      arguments = [@paths.binary, "serve", "--config", config_path]

      XML.build(indent: "  ", version: "1.0", encoding: "UTF-8") do |xml|
        xml.dtd("plist", "-//Apple//DTD PLIST 1.0//EN", "http://www.apple.com/DTDs/PropertyList-1.0.dtd")
        xml.element("plist", version: "1.0") do
          xml.element("dict") do
            entry(xml: xml, key: "Label") { xml.element("string") { xml.text LABEL } }
            entry(xml: xml, key: "ProgramArguments") do
              xml.element("array") do
                arguments.each { |argument| xml.element("string") { xml.text argument } }
              end
            end
            entry(xml: xml, key: "Sockets") do
              xml.element("dict") do
                entry(xml: xml, key: "Listeners") do
                  xml.element("dict") do
                    entry(xml: xml, key: "SockPathName") { xml.element("string") { xml.text socket } }
                    entry(xml: xml, key: "SockPathMode") { xml.element("integer") { xml.text SOCKET_MODE.to_s } }
                    entry(xml: xml, key: "SockPathOwner") { xml.element("integer") { xml.text "0" } }
                    entry(xml: xml, key: "SockPathGroup") { xml.element("integer") { xml.text group_gid.to_s } }
                  end
                end
              end
            end
            entry(xml: xml, key: "StandardErrorPath") { xml.element("string") { xml.text @paths.log } }
          end
        end
      end
    end

    private def entry(*, xml : XML::Builder, key : String, & : ->) : Nil
      xml.element("key") { xml.text key }
      yield
    end

    # Nil when `plutil -lint` accepts *xml* on its standard input, else what
    # it reports, or that it ran out of *timeout*.
    def self.lint(xml : String, *, timeout : Time::Span = CommandRunner::COMMAND_TIMEOUT) : String?
      result = CommandRunner.run([PLUTIL, "-lint", "-"], input: xml, timeout: timeout)
      return if result.success?

      result.timed_out? ? result.outcome : "#{result.output}#{result.error}".strip
    end

    # Installs and loads the daemon; returns the exit code. Refuses unless
    # it runs as root, before it looks at anything else. *group* is created
    # when it is missing and is the main group of a starter configuration;
    # an existing configuration keeps its own, which the property list and
    # the printed `dseditgroup` hint then use (CA7). *sudo_user*, when
    # known, is the user the hint names.
    def install(*, group : String, sudo_user : String?, output : IO, error : IO) : Int32
      unless root?
        code = refuse("install", error: error)
        return code
      end

      check_directories
      config = prepare_config(group: group, output: output)
      xml = prepare_plist(config)
      copy_binary
      output.puts "installed #{@paths.binary}"
      activate(xml, socket: config.socket, output: output)
      print_group_hint(group: config.group, sudo_user: sudo_user, output: output)
      0
    rescue ex : Failure | Config::Error | ArgumentError | IO::Error | File::Error
      error.puts "tunnelgeist: #{ex.message}"
      1
    end

    # The configuration the daemon will run with, after creating *group*
    # when it is missing, the configuration directories when they are
    # missing, and the starter configuration for *group* when there is no
    # main file. Loading it runs the daemon's own checks (CC2) before
    # anything replaces or unloads the working daemon.
    private def prepare_config(*, group : String, output : IO) : Config
      ensure_group(group, output: output)
      make_directory(@paths.config_directory)
      make_directory(@paths.clients_directory)
      write_starter(group: group, output: output)
      @load_config.call(@paths.config)
    end

    # Writes the starter configuration for *group* unless something, even
    # a broken link, is at the main file's path: an operator's
    # configuration is never replaced.
    private def write_starter(*, group : String, output : IO) : Nil
      if File.info?(@paths.config, follow_symlinks: false)
        output.puts "kept #{@paths.config}"
      else
        write_file(@paths.config, content: Starter.json(socket: Protocol::DEFAULT_SOCKET, group: group), mode: 0o644)
        output.puts "wrote #{@paths.config}"
      end
    end

    # The property list for *config*, linted before anything replaces or
    # unloads the working daemon.
    private def prepare_plist(config : Config) : String
      xml = plist(config_path: @paths.config, socket: config.socket, group_gid: config.membership.gid)
      problem = @lint.call(xml)
      if problem
        raise Failure.new("the property list does not pass #{PLUTIL} -lint: #{problem}", program: PLUTIL)
      end
      xml
    end

    # Unloads the daemon, writes the property list *xml* and loads the
    # daemon from it, which listens on *socket*.
    private def activate(xml : String, *, socket : String, output : IO) : Nil
      bootout(output)
      write_file(@paths.plist, content: xml, mode: 0o644)
      output.puts "wrote #{@paths.plist}"
      launchctl!("bootstrap", "system", @paths.plist)
      output.puts "loaded #{LABEL}; launchd listens on #{socket}"
    end

    # Prints how to add a user, *sudo_user* when known, to *group*.
    private def print_group_hint(*, group : String, sudo_user : String?, output : IO) : Nil
      output.puts "Add a user to the group #{group} with:"
      output.puts "  sudo #{DSEDITGROUP} -o edit -a #{sudo_user || "USER"} -t user #{group}"
    end

    # Unloads the daemon and removes its property list and binary; leaves
    # the group and the configuration directory (CA8), and says so for the
    # directory. Returns the exit code.
    def uninstall(*, output : IO, error : IO) : Int32
      unless root?
        code = refuse("uninstall", error: error)
        return code
      end

      bootout(output)
      output.puts "removed #{@paths.plist}" if File.delete?(@paths.plist)
      output.puts "removed #{@paths.binary}" if File.delete?(@paths.binary)
      output.puts "left #{@paths.config_directory}" if Dir.exists?(@paths.config_directory)
      0
    rescue ex : IO::Error | File::Error
      error.puts "tunnelgeist: #{ex.message}"
      1
    end

    private def root? : Bool
      @effective_uid.call == 0
    end

    private def refuse(command : String, *, error : IO) : Int32
      error.puts "tunnelgeist: #{command} must run as root"
      1
    end

    # Creates *group* with `dseditgroup` when the system does not know it.
    # The property list takes its gid from the loaded configuration, whose
    # group may be another one.
    private def ensure_group(group : String, *, output : IO) : Nil
      return if @find_group.call(group)

      result = run(DSEDITGROUP, "-o", "create", group)
      unless result.success?
        raise Failure.new("#{DSEDITGROUP} -o create #{group} #{result.outcome}",
          program: DSEDITGROUP, exit_status: result.exit_status, timed_out_after: result.timed_out_after)
      end

      output.puts "created group #{group}"
      raise Failure.new("group #{group} not found after creating it") unless @find_group.call(group)
    end

    # Copies the running executable to the binary path, mode 0755 (UC3),
    # through a file in the same directory, so the path never holds
    # a partial binary.
    private def copy_binary : Nil
      source = @executable
      raise Failure.new("cannot find the running executable") unless source

      make_directory(File.dirname(@paths.binary))
      open_executable(source) do |executable|
        replace(@paths.binary, mode: 0o755) { |file| IO.copy(executable, file) }
      end
    end

    # Opens *source*, the resolved path of the running executable, without
    # following a symbolic link and yields it. Under Homebrew it lies in a
    # directory its user owns: opened by name as root, a link put there
    # after the path was resolved could have root copy a file only root
    # may read to a path everyone may read.
    private def open_executable(source : String, & : IO ->) : Nil
      descriptor = LibC.open(source, LibC::O_RDONLY | LibC::O_NOFOLLOW | LibC::O_CLOEXEC)
      if descriptor < 0
        raise Failure.new("cannot open the running executable #{source} without following a symbolic link: " \
                          "#{Errno.value.message}")
      end

      executable = IO::FileDescriptor.new(descriptor)
      begin
        raise Failure.new("the running executable #{source} is not a regular file") unless executable.info.file?

        yield executable
      ensure
        executable.close
      end
    end

    # Checks every directory install writes in or creates directories in,
    # before it creates the group or writes anything, so a refusal leaves
    # nothing behind: install writes there as root, and a user who may
    # write one of them, or a directory above one, could swap what install
    # writes for a link. Existing directories are refused, never changed.
    #
    # For the binary (UC3) that is every existing directory from the root
    # of `Paths` down to the binary's; for the configuration, the
    # configuration directory and an existing `clients.d`; and for both,
    # the nearest existing directory and every directory above it up to
    # `/`, which `check_ancestors` checks.
    private def check_directories : Nil
      @paths.binary_directories.each do |directory|
        check_directory(directory) if File.info?(directory, follow_symlinks: false)
      end
      check_tree(File.dirname(@paths.binary))
      check_tree(@paths.config_directory)
      clients = @paths.clients_directory
      check_directory(clients) if File.info?(clients, follow_symlinks: false)
    end

    # Checks *path*, or the nearest existing directory above it that
    # `make_directory` would create it in, with `check_directory`, and the
    # directories above that with `check_ancestors`.
    private def check_tree(path : String) : Nil
      existing = existing_ancestor(path)
      check_directory(existing)
      check_ancestors(existing)
    end

    # Raises unless each directory above *path* up to `/` is a directory,
    # not a symbolic link, owned by root or the owner and writable by no
    # one else: whoever may write one could rename *path* away and put
    # their own directory in its place.
    private def check_ancestors(path : String) : Nil
      current = path
      loop do
        parent = File.dirname(current)
        break if parent == current

        check_directory(parent, owners: {0_u32, @owner.uid})
        current = parent
      end
    end

    # *path* when something is there, else the nearest existing directory
    # above it.
    private def existing_ancestor(path : String) : String
      existing = path
      until File.info?(existing, follow_symlinks: false)
        existing = File.dirname(existing)
      end
      existing
    end

    # Creates *path*, and its missing parents first, mode 0755 and owned by
    # the owner (root:wheel for a real installation). An existing directory
    # is left as it is; `check_directories` has refused one that is not
    # safe to write in.
    private def make_directory(path : String) : Nil
      return if File.info?(path, follow_symlinks: false)

      make_directory(File.dirname(path))
      Dir.mkdir(path, 0o755)
      made = File.info(path, follow_symlinks: false)
      unless made.directory? && made.owner_id == LibSystem.geteuid.to_s
        raise Failure.new("#{path} is not the directory install created")
      end
      File.chown(path, @owner.uid.to_i, @owner.gid.to_i, follow_symlinks: false)
      change_mode(path, mode: 0o755)
    end

    # Raises unless *path* is a directory, not a symbolic link, owned by
    # the owner, root for a real installation, that no one else may write:
    # otherwise another user could swap what install writes there (UC3).
    # The message names *path* and what is wrong with it.
    # *owners* are the uids that may own it.
    private def check_directory(path : String, *, owners : Enumerable(UInt32) = {@owner.uid}) : Nil
      problem = directory_problem(File.info(path, follow_symlinks: false), owners: owners)
      if problem
        raise Failure.new("#{path} must be a directory owned by root and writable only by root: #{problem}")
      end
    end

    # What keeps the directory *info* describes from being safe to write
    # in, nil when nothing does; *owners* are the uids that may own it.
    private def directory_problem(info : File::Info, *, owners : Enumerable(UInt32)) : String?
      if info.symlink?
        "it is a symbolic link"
      elsif !info.directory?
        "it is not a directory"
      elsif !owners.any? { |uid| info.owner_id == uid.to_s }
        "it is owned by uid #{info.owner_id}"
      elsif info.permissions.group_write? || info.permissions.other_write?
        "its mode is #{"%04o" % info.permissions.value}"
      end
    end

    # Sets the mode of *path* without following a symbolic link there.
    private def change_mode(path : String, *, mode : Int32) : Nil
      if LibSystem.lchmod(path, mode) != 0
        raise File::Error.from_errno("lchmod", file: path)
      end
    end

    private def write_file(path : String, *, content : String, mode : Int32) : Nil
      replace(path, mode: mode, &.print(content))
    end

    # Writes *path* through a temporary file beside it that the block
    # fills, then sets *mode* and the owner (root:wheel for a real
    # installation), and renames it over *path*. The temporary file is
    # created mode 0600, so no one else can read it before *mode* is set.
    # The binary and the configuration go into directories that passed
    # `check_directory`, so no one else can put a link at the temporary
    # path for the block to write through, or a file at *path* for the
    # rename to replace.
    private def replace(path : String, *, mode : Int32, & : IO ->) : Nil
      temporary = "#{path}.#{Random::Secure.hex(8)}.tmp"
      begin
        File.open(temporary, "wb", perm: 0o600) { |file| yield file }
        File.chown(temporary, @owner.uid.to_i, @owner.gid.to_i, follow_symlinks: false)
        change_mode(temporary, mode: mode)
        File.rename(temporary, path)
      rescue error
        File.delete?(temporary)
        raise error
      end
    end

    # Unloads the daemon. A failure does not stop `install` or `uninstall`,
    # since the daemon may not be loaded; it is reported on *output*.
    private def bootout(output : IO) : Nil
      result = run(LAUNCHCTL, "bootout", "system/#{LABEL}")
      return if result.success?

      # A daemon that is not loaded makes `launchctl` fail, not hang.
      hint = result.timed_out? ? "" : " (not loaded?)"
      output.puts "launchctl bootout #{result.outcome}#{hint}"
    end

    private def launchctl!(*arguments : String) : Nil
      result = run(LAUNCHCTL, *arguments)
      return if result.success?

      raise Failure.new("#{LAUNCHCTL} #{arguments.join(' ')} #{result.outcome}",
        program: LAUNCHCTL, exit_status: result.exit_status, timed_out_after: result.timed_out_after)
    end

    # Runs a program by absolute path with an empty environment (UC4).
    private def run(*argv : String) : CommandRunner::Result
      @run.call(argv.to_a)
    end
  end
end
