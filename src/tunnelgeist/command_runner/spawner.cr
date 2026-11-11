{% skip_file unless flag?(:darwin) %}

require "c/fcntl"
require "c/signal"
require "./lib_spawn"

module Tunnelgeist
  module CommandRunner
    # Starts a program with `posix_spawn` for `Execution`, which the
    # standard library's `Process.new` cannot do with these properties:
    #
    # - The program leads a process group of its own, so that a timeout can
    #   stop the processes it started along with it.
    # - Every signal has its default action and none is blocked. The daemon
    #   ignores `PIPE`, as every Crystal program does, and an ignored signal
    #   stays ignored across `exec`.
    # - The program inherits no descriptor but its standard input, output
    #   and error (`POSIX_SPAWN_CLOEXEC_DEFAULT`), whoever opened the others
    #   and whether or not they have close-on-exec.
    module Spawner
      # Starts *argv* by absolute path, without a shell and with an empty
      # environment, with *input*, *output* and *error* as its standard
      # input, output and error; with the null device as standard input
      # when *input* is nil. Returns the running `Process`. Raises
      # `IO::Error` when the program cannot be started.
      def self.start(argv : Array(String), *, input : IO::FileDescriptor?, output : IO::FileDescriptor,
                     error : IO::FileDescriptor) : Process
        pid = with_attributes do |attributes|
          with_file_actions do |actions|
            redirect(actions, fd: 0, to: input)
            redirect(actions, fd: 1, to: output)
            redirect(actions, fd: 2, to: error)
            spawn(argv, attributes: attributes, actions: actions)
          end
        end
        # The runtime reaps every child when `CHLD` arrives and keeps the
        # status of one nobody waits for yet, so a program that ended
        # before this line is still reported to `Process#wait`.
        Process.new(Crystal::System::Process.new(pid))
      end

      # Yields attributes that make the program a group leader with every
      # signal at its default action and none blocked.
      private def self.with_attributes(&)
        attributes = uninitialized LibSpawn::PosixSpawnattrT
        check(LibSpawn.posix_spawnattr_init(pointerof(attributes)), call: "posix_spawnattr_init")
        begin
          flags = LibSpawn::POSIX_SPAWN_SETPGROUP | LibSpawn::POSIX_SPAWN_SETSIGDEF |
                  LibSpawn::POSIX_SPAWN_SETSIGMASK | LibSpawn::POSIX_SPAWN_CLOEXEC_DEFAULT
          check(LibSpawn.posix_spawnattr_setflags(pointerof(attributes), flags.to_i16), call: "posix_spawnattr_setflags")
          check(LibSpawn.posix_spawnattr_setpgroup(pointerof(attributes), 0), call: "posix_spawnattr_setpgroup")

          # `KILL` and `STOP` cannot be caught or ignored, so they always
          # have their default action.
          defaults = uninitialized LibC::SigsetT
          LibC.sigfillset(pointerof(defaults))
          LibC.sigdelset(pointerof(defaults), Signal::KILL.value)
          LibC.sigdelset(pointerof(defaults), Signal::STOP.value)
          check(LibSpawn.posix_spawnattr_setsigdefault(pointerof(attributes), pointerof(defaults)), call: "posix_spawnattr_setsigdefault")

          mask = uninitialized LibC::SigsetT
          LibC.sigemptyset(pointerof(mask))
          check(LibSpawn.posix_spawnattr_setsigmask(pointerof(attributes), pointerof(mask)), call: "posix_spawnattr_setsigmask")

          yield pointerof(attributes)
        ensure
          LibSpawn.posix_spawnattr_destroy(pointerof(attributes))
        end
      end

      # Yields an empty list of file actions.
      private def self.with_file_actions(&)
        actions = uninitialized LibSpawn::PosixSpawnFileActionsT
        check(LibSpawn.posix_spawn_file_actions_init(pointerof(actions)), call: "posix_spawn_file_actions_init")
        begin
          yield pointerof(actions)
        ensure
          LibSpawn.posix_spawn_file_actions_destroy(pointerof(actions))
        end
      end

      # Makes *fd* of the program a copy of *to*, or the null device opened
      # for reading when *to* is nil.
      private def self.redirect(actions : LibSpawn::PosixSpawnFileActionsT*, *, fd : Int32, to io : IO::FileDescriptor?) : Nil
        if io
          check(LibSpawn.posix_spawn_file_actions_adddup2(actions, io.fd, fd), call: "posix_spawn_file_actions_adddup2")
        else
          check(LibSpawn.posix_spawn_file_actions_addopen(actions, fd, "/dev/null", LibC::O_RDONLY, 0), call: "posix_spawn_file_actions_addopen")
        end
      end

      # Starts *argv* and returns its pid.
      private def self.spawn(argv : Array(String), *, attributes : LibSpawn::PosixSpawnattrT*,
                             actions : LibSpawn::PosixSpawnFileActionsT*) : LibC::PidT
        arguments = argv.map(&.check_no_null_byte.to_unsafe) << Pointer(UInt8).null
        environment = [Pointer(UInt8).null]
        pid = uninitialized LibC::PidT
        result = LibSpawn.posix_spawn(pointerof(pid), argv[0], actions, attributes, arguments.to_unsafe, environment.to_unsafe)
        raise IO::Error.from_os_error("Cannot start #{argv[0]}", Errno.new(result)) unless result == 0

        pid
      end

      # Raises `IO::Error` naming *call* unless *result*, an errno value or
      # 0, is 0.
      private def self.check(result : Int32, *, call : String) : Nil
        raise IO::Error.from_os_error(call, Errno.new(result)) unless result == 0
      end
    end
  end
end
