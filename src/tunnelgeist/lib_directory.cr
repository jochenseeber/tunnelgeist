{% skip_file unless flag?(:darwin) %}

require "c/dirent"
require "c/fcntl"
require "c/sys/stat"
require "c/sys/types"

module Tunnelgeist
  # The descriptor-relative directory access `TrustedDirectory` and
  # `install` need and the standard library's `LibC` lacks. Values from the
  # macOS SDK headers (`xcrun --show-sdk-path`, then `usr/include/...`).
  lib LibDirectory
    # Fails the open unless the path names a directory (sys/fcntl.h).
    O_DIRECTORY = 0x00100000
    # The `fcntl` command that duplicates a descriptor with `FD_CLOEXEC`
    # set (sys/fcntl.h).
    F_DUPFD_CLOEXEC = 67

    # Opens *path* relative to the directory descriptor *fd* (fcntl.h).
    fun openat(fd : ::LibC::Int, path : ::LibC::Char*, oflag : ::LibC::Int, ...) : ::LibC::Int

    # Creates the directory *path* relative to the directory descriptor
    # *fd* (sys/stat.h).
    fun mkdirat(fd : ::LibC::Int, path : ::LibC::Char*, mode : ::LibC::ModeT) : ::LibC::Int
    # Renames *from* relative to *from_fd* to *to* relative to *to_fd*
    # (stdio.h).
    fun renameat(from_fd : ::LibC::Int, from : ::LibC::Char*, to_fd : ::LibC::Int, to : ::LibC::Char*) : ::LibC::Int
    # Removes the file *path* relative to the directory descriptor *fd*;
    # *flag* is 0 for a file (unistd.h).
    fun unlinkat(fd : ::LibC::Int, path : ::LibC::Char*, flag : ::LibC::Int) : ::LibC::Int

    # A directory stream on the directory descriptor *fd*, which the
    # stream then owns: `closedir` closes it (dirent.h), and the status
    # of *path* relative to *fd*, of a symbolic link itself with
    # `AT_SYMLINK_NOFOLLOW` (sys/stat.h). The x86_64 library keeps the
    # 32-bit inode variants under the plain names; the standard library's
    # `readdir` and `Stat` there are the 64-bit ones.
    {% if flag?(:x86_64) %}
      fun fdopendir = "fdopendir$INODE64"(fd : ::LibC::Int) : ::LibC::DIR*
      fun fstatat = "fstatat$INODE64"(fd : ::LibC::Int, path : ::LibC::Char*, buf : ::LibC::Stat*,
                                      flag : ::LibC::Int) : ::LibC::Int
    {% else %}
      fun fdopendir(fd : ::LibC::Int) : ::LibC::DIR*
      fun fstatat(fd : ::LibC::Int, path : ::LibC::Char*, buf : ::LibC::Stat*, flag : ::LibC::Int) : ::LibC::Int
    {% end %}
  end
end
