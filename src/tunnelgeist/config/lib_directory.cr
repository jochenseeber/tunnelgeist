{% skip_file unless flag?(:darwin) %}

require "c/dirent"
require "c/fcntl"
require "c/sys/stat"
require "c/sys/types"

module Tunnelgeist
  struct Config
    # The descriptor-relative directory access `Config::TrustedDirectory`
    # needs and the standard library's `LibC` lacks. Values from the macOS
    # SDK headers (`xcrun --show-sdk-path`, then `usr/include/...`).
    lib LibDirectory
      # Fails the open unless the path names a directory (sys/fcntl.h).
      O_DIRECTORY = 0x00100000

      # Opens *path* relative to the directory descriptor *fd* (fcntl.h).
      fun openat(fd : ::LibC::Int, path : ::LibC::Char*, oflag : ::LibC::Int, ...) : ::LibC::Int
      # A new descriptor for the open file of *fd* (unistd.h).
      fun dup(fd : ::LibC::Int) : ::LibC::Int

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
end
