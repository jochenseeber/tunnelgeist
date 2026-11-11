{% skip_file unless flag?(:darwin) %}

require "c/signal"
require "c/sys/types"

module Tunnelgeist
  module CommandRunner
    # `posix_spawn` and its attributes (spawn.h, sys/spawn.h), which the
    # standard library's `LibC` lacks. Values from the macOS SDK headers
    # (`xcrun --show-sdk-path`, then `usr/include/sys/spawn.h`). Each function
    # returns 0 or an errno value.
    lib LibSpawn
      # The child joins the process group `posix_spawnattr_setpgroup` names;
      # 0 makes it the leader of a group of its own.
      POSIX_SPAWN_SETPGROUP = 0x0002
      # The signals of `posix_spawnattr_setsigdefault` get their default
      # action in the child.
      POSIX_SPAWN_SETSIGDEF = 0x0004
      # The child starts with the mask of `posix_spawnattr_setsigmask`.
      POSIX_SPAWN_SETSIGMASK = 0x0008
      # Darwin only: the child inherits no descriptor but those the file
      # actions name, as if every other one had close-on-exec.
      POSIX_SPAWN_CLOEXEC_DEFAULT = 0x4000

      # Opaque handles the init functions allocate (`void *` in spawn.h).
      alias PosixSpawnattrT = Void*
      alias PosixSpawnFileActionsT = Void*

      fun posix_spawn(pid : ::LibC::PidT*, path : ::LibC::Char*, file_actions : PosixSpawnFileActionsT*,
                      attrp : PosixSpawnattrT*, argv : ::LibC::Char**, envp : ::LibC::Char**) : ::LibC::Int

      fun posix_spawnattr_init(attr : PosixSpawnattrT*) : ::LibC::Int
      fun posix_spawnattr_destroy(attr : PosixSpawnattrT*) : ::LibC::Int
      fun posix_spawnattr_setflags(attr : PosixSpawnattrT*, flags : ::LibC::Short) : ::LibC::Int
      fun posix_spawnattr_setpgroup(attr : PosixSpawnattrT*, pgroup : ::LibC::PidT) : ::LibC::Int
      fun posix_spawnattr_setsigdefault(attr : PosixSpawnattrT*, sigdefault : ::LibC::SigsetT*) : ::LibC::Int
      fun posix_spawnattr_setsigmask(attr : PosixSpawnattrT*, sigmask : ::LibC::SigsetT*) : ::LibC::Int

      fun posix_spawn_file_actions_init(actions : PosixSpawnFileActionsT*) : ::LibC::Int
      fun posix_spawn_file_actions_destroy(actions : PosixSpawnFileActionsT*) : ::LibC::Int
      fun posix_spawn_file_actions_adddup2(actions : PosixSpawnFileActionsT*, fd : ::LibC::Int, newfd : ::LibC::Int) : ::LibC::Int
      fun posix_spawn_file_actions_addopen(actions : PosixSpawnFileActionsT*, fd : ::LibC::Int, path : ::LibC::Char*,
                                           oflag : ::LibC::Int, mode : ::LibC::ModeT) : ::LibC::Int
    end
  end
end
