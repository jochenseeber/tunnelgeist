{% skip_file unless flag?(:darwin) %}

require "./directory/missing"
require "./trusted_file"

module Tunnelgeist
  struct Config
    # An open configuration directory that, with every directory above it,
    # has passed `TrustPolicy`; the loader reads every file through one.
    # `TrustedDirectory` is the one the daemon uses. Every refusal is a
    # `Config::Error` naming the path up to the object that failed, and
    # `Missing` when that does not exist.
    abstract class Directory
      # The path of the directory, from `/`.
      abstract def path : String

      # The text of the file *name* in this directory, after the file has
      # passed `TrustPolicy`.
      abstract def read(name : String) : TrustedFile

      # The names in this directory, `.` and `..` left out.
      abstract def names : Array(String)

      # The directory reached from this one through the plain names *names*,
      # each checked on the way, and a new one for this directory itself
      # when there are none. The caller closes it; this one stays open.
      abstract def open(names : Array(String)) : Directory

      # Closes the directory.
      abstract def close : Nil

      # Runs the block with the directory `open` returns for *names* and
      # closes it afterwards.
      def descend(names : Array(String), &)
        opened = open(names)
        begin
          yield opened
        ensure
          opened.close
        end
      end
    end
  end
end
