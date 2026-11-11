{% skip_file unless flag?(:darwin) %}

require "log"
require "socket"
require "./cli/command"
require "./cli/commit"
require "./cli/listener"
require "./cli/options"
require "./cli/socket_path"
require "./config"
require "./config/error"
require "./config/holder"
require "./departure_watcher"
require "./handler"
require "./install"
require "./launchd"
require "./lib_system"
require "./peer"
require "./registry"
require "./server"
require "./version"

module Tunnelgeist
  # The command line of `tunnelgeist` (UA5, UA9): `serve`, `install`,
  # `uninstall` and `help`. `run` takes the streams and the sudo user as
  # arguments so a spec can drive it; only `bin/tunnelgeist_macos.cr`
  # passes the real ones.
  module CLI
    # The exit code for a command line the tool cannot use.
    USAGE_ERROR = 2

    USAGE = <<-TEXT
      Usage: tunnelgeist <command> [options]

      Commands:
        serve      Serve utun helper requests (started by launchd)
        install    Install the daemon as a LaunchDaemon (as root)
        uninstall  Remove the LaunchDaemon and its binary (as root)
        version    Print the version and the commit it was built from
        help       Print this text

      Run 'tunnelgeist <command> --help' for the options of a command.
      TEXT

    # Runs the command named by the first of *args* and returns the exit
    # code: 0 on success, 2 for a command line it cannot use, 1 for a
    # failure while running. Messages go to *error*, help to *output*.
    # *sudo_user* is the user who ran the program through `sudo`, whom the
    # hint `install` prints names.
    def self.run(args : Array(String), *, output : IO, error : IO, sudo_user : String? = nil) : Int32
      argument = args.first?
      command = argument ? Command.from_argument?(argument) : Command::Help
      unless command
        error.puts "tunnelgeist: unknown command #{argument.inspect}"
        error.puts "Run 'tunnelgeist help' for the commands."
        return USAGE_ERROR
      end

      dispatch(command, args: args.skip(1), output: output, error: error, sudo_user: sudo_user)
    rescue ex : ArgumentError
      error.puts "tunnelgeist: #{ex.message}"
      error.puts "Run 'tunnelgeist #{args.first?} --help' for the options."
      USAGE_ERROR
    end

    # `help` takes no options and ignores any arguments; every other
    # command reads its options from *args* first.
    private def self.dispatch(command : Command, *, args : Array(String), output : IO, error : IO,
                              sudo_user : String?) : Int32
      case command
      in .help?
        output.puts USAGE
        0
      in .serve?
        with_options(command, args: args, output: output) { |options| serve(config_path: options.config, error: error) }
      in .install?
        with_options(command, args: args, output: output) do |options|
          installer = Install.new(paths: Install::Paths.default(config: options.config))
          installer.install(group: options.group, sudo_user: sudo_user, output: output, error: error)
        end
      in .uninstall?
        with_options(command, args: args, output: output) { Install.new.uninstall(output: output, error: error) }
      in .version?
        with_options(command, args: args, output: output) do
          output.puts "tunnelgeist #{VERSION} (#{COMMIT})"
          0
        end
      end
    end

    # Parses *args* with the options of *command* and yields them; prints
    # the help of *command* instead when they ask for it.
    private def self.with_options(command : Command, *, args : Array(String), output : IO, & : Options -> Int32) : Int32
      options = Options.parse(command: command, args: args)
      if options.help?
        output.puts options.usage
        return 0
      end
      yield options
    end

    # Serves requests until idle (UA5) with the configuration at
    # *config_path* (CA6). The configuration is loaded before anything
    # else, so a bad one ends the daemon at start with the error on
    # *error*; once it serves, `SIGHUP` loads it again (CA5).
    private def self.serve(*, config_path : String, error : IO) : Int32
      config = load_config(config_path, error: error)
      return 1 unless config

      # `Log.builder` must exist before any log does; see
      # spec/spec_helper.cr.
      Log.setup(:info, Log::IOBackend.new(error, dispatcher: :sync))
      log = Log.for("tunnelgeist")
      listener = open_listener(config: config, log: log)
      return 1 unless listener

      holder = Config::Holder.new(config, listening: listener.path)
      run_server(listener: listener.server, holder: holder, config_path: config_path, log: log)
    end

    # The configuration at *path*, or nil after printing why it cannot be
    # loaded.
    private def self.load_config(path : String, *, error : IO) : Config?
      Config.load(path)
    rescue ex : Config::Error
      error.puts "tunnelgeist: #{ex.message}"
      nil
    end

    # The socket launchd hands over when it started the daemon, else the
    # socket of *config*, bound here (CA6); nil after logging why there is
    # none. The loader has checked the configured path, so an
    # `ArgumentError` here is a bind failure like any other, not a bad
    # command line.
    private def self.open_listener(*, config : Config, log : Log) : Listener?
      server = Launchd.listener
      listener = server ? launchd_listener(server, config: config, log: log) : bound_listener(config, log: log)
      listener
    rescue ex : IO::Error | File::Error | Socket::Error | ArgumentError
      log.error { "no listening socket: #{ex.message}" }
      nil
    end

    # *server*, the socket launchd passed, with the path it is bound to,
    # which the property list names. Warns when that is not the configured
    # socket: launchd keeps the path until `install` writes a new property
    # list. Closes *server* when its path cannot be read or it has none.
    private def self.launchd_listener(server : UNIXServer, *, config : Config, log : Log) : Listener
      path = begin
        SocketPath.bound(server)
      rescue ex
        server.close
        raise ex
      end
      log.info { "listening socket=#{path} source=launchd" }
      unless path == config.socket
        log.warn { "configuration socket #{config.socket} differs from the listening socket #{path}, reinstall to apply" }
      end
      Listener.new(server: server, path: path)
    end

    # The socket of *config*, bound here.
    private def self.bound_listener(config : Config, *, log : Log) : Listener
      server = bind(config.socket, gid: config.membership.gid, log: log)
      log.info { "listening socket=#{config.socket} source=bound" }
      Listener.new(server: server, path: config.socket)
    end

    # A watcher that stops would miss departures and leave the entries of
    # gone devices on recycled units, so a failure runs the block and closes
    # *listener*, which stops the daemon (fail closed).
    private def self.build_watcher(registry : Registry, *, listener : UNIXServer, log : Log, &failed : ->) : DepartureWatcher
      DepartureWatcher.new(registry, log: log.for("departure"), on_failure: ->(_reason : String) do
        failed.call
        listener.close
      end)
    end

    # Runs the server on *listener* until it closes (idle, signal or a
    # failed departure watcher) and returns the exit code. Each connection is
    # judged by the configuration *holder* has when it is accepted; `SIGHUP`
    # loads *config_path* into it again. The watcher is built before the
    # handler, which drains it before it registers a new device.
    private def self.run_server(*, listener : UNIXServer, holder : Config::Holder, config_path : String,
                                log : Log) : Int32
      config = holder.current
      registry = Registry.new
      watcher_failed = false
      watcher = build_watcher(registry, listener: listener, log: log) { watcher_failed = true }
      handler = Handler.new(registry, admit: ->(peer : Peer) { holder.authorizer.admit(peer) }, group: config.group,
        log: log.for("handler"), drain_departures: -> { watcher.drain })
      begin
        watcher.start
        # launchd stops the daemon with SIGTERM; closing the listener ends
        # `Server#run`, so the cleanup below runs.
        Process.on_terminate { listener.close }
        # Crystal calls a trap handler in a fiber of its own, outside the
        # signal handler, so the reload may read files and ask the
        # directory service; requests go on in the other fibers meanwhile.
        # SIGHUP reloads the configuration (CA5). `Process.on_terminate`
        # also traps it, as a hangup that ends the process; this trap
        # replaces that handler. ameba's `Lint/SignalTrap` would hand it to
        # `Process.on_terminate`, which would make a reload stop the daemon.
        Signal::HUP.trap { holder.reload(load: -> { Config.load(config_path) }, log: log) } # ameba:disable Lint/SignalTrap
        log.info { "serving group=#{config.group} clients=#{config.clients.size} config=#{config_path}" }
        Server.new(listener, handler: handler, registry: registry, log: log.for("server")).run
        if watcher_failed
          log.error { "departure watcher failed, exiting" }
          return 1
        end
        log.info { "listener closed (idle or signal), exiting" }
        0
      rescue ex : IO::Error
        log.error { "#{ex.message}" }
        1
      ensure
        Process.restore_interrupts!
        watcher.close
        # `UNIXServer#close` removes a socket path the daemon bound.
        listener.close
        # Reset only now: a hangup before this still reloads, where the
        # default action would end the process before the close above
        # removed the socket path.
        Signal::HUP.reset
      end
    end

    # Binds *path* when launchd did not start the daemon (UT3, CA6): owner
    # root and *gid*, mode 0660. A stale socket file is removed first; a
    # socket something listens on and any other file are left and refused.
    # Not as root the owner stays, which the log says.
    private def self.bind(path : String, *, gid : UInt32, log : Log) : UNIXServer
      SocketPath.clear(path)
      listener = listen_owner_only(path)
      begin
        secure_socket(path, gid: gid, log: log)
      rescue ex
        listener.close
        raise ex
      end
      listener
    end

    # Listens on *path* with a socket only its owner may connect to until
    # `secure_socket` sets the mode.
    private def self.listen_owner_only(path : String) : UNIXServer
      previous = LibC.umask(0o177)
      begin
        UNIXServer.new(path)
      ensure
        LibC.umask(previous)
      end
    end

    # Gives the socket at *path* the owner root and *gid*, or keeps its
    # owner and logs that when not root, sets mode 0660, and checks that
    # *path* is still a socket.
    private def self.secure_socket(path : String, *, gid : UInt32, log : Log) : Nil
      if LibSystem.geteuid == 0
        File.chown(path, 0, gid.to_i)
      else
        log.warn { "not root: #{path} keeps its owner, not root:#{gid}" }
      end
      # Neither call follows a symbolic link put in place of the socket.
      if LibSystem.lchmod(path, Install::SOCKET_MODE) != 0
        raise File::Error.from_errno("lchmod", file: path)
      end
      unless File.info(path, follow_symlinks: false).type.socket?
        raise File::Error.new("#{path} is no longer a socket", file: path)
      end
    end
  end
end
