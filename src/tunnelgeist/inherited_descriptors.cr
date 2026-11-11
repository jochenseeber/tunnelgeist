{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  # The descriptors a child process would inherit. The daemon runs `ifconfig`
  # and `route` as root, so a descriptor opened without close-on-exec, by a
  # library or by launchd, must not reach them.
  module InheritedDescriptors
    # Sets `FD_CLOEXEC` on every open descriptor above 2, enumerated from
    # `/dev/fd`. A descriptor that closed meanwhile is skipped; any other
    # failure raises `IO::Error`.
    def self.mark_close_on_exec : Nil
      # Collected first, so the directory handle is closed before the loop.
      Dir.children("/dev/fd").each do |entry|
        fd = entry.to_i?
        mark(fd) if fd && fd > 2
      end
    end

    private def self.mark(fd : Int32) : Nil
      flags = LibC.fcntl(fd, LibC::F_GETFD)
      return unless check(flags, call: "fcntl(#{fd}, F_GETFD)")
      return if (flags & LibC::FD_CLOEXEC) != 0

      result = LibC.fcntl(fd, LibC::F_SETFD, flags | LibC::FD_CLOEXEC)
      check(result, call: "fcntl(#{fd}, F_SETFD)")
    end

    # False when *result* is a failure because the descriptor closed
    # meanwhile; raises `IO::Error` for any other failure of *call*; true on
    # success.
    private def self.check(result : Int32, *, call : String) : Bool
      return true unless result < 0
      return false if Errno.value == Errno::EBADF

      raise IO::Error.from_errno(call)
    end
  end
end
