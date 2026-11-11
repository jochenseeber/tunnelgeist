require "file_utils"
require "random/secure"

# Fresh directories for the files and sockets a spec creates, each below the
# real path of the temporary directory (`$TMPDIR`) and removed afterwards.
# The real path, because the configuration loader and `install` refuse a
# symbolic link among the directories they check, and macOS's temporary
# directory lies below `/var`, which is one.
module TunnelgeistTemporaryDirectory
  extend self

  # The longest path a Unix socket address holds: `sun_path` has 104 bytes,
  # the last for the terminating NUL.
  SOCKET_PATH_LIMIT = 103

  # Runs the block with a new empty directory, mode 0700, and removes it with
  # everything in it afterwards.
  def with_temporary_directory(& : String ->)
    directory = create_temporary_directory
    begin
      yield directory
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  # A new empty directory, mode 0700, with a short unique name; the caller
  # removes it.
  def create_temporary_directory : String
    path = File.join(File.realpath(Dir.tempdir), "tg-#{Random::Secure.hex(4)}")
    Dir.mkdir(path, 0o700)
    # The process's umask may have narrowed the mode, never widened it; set
    # it exactly.
    File.chmod(path, 0o700)
    path
  end

  # The path of the socket *name* in *directory*; raises `ArgumentError`
  # when it is too long for a Unix socket address, which a long `$TMPDIR`
  # makes it.
  def socket_path(directory : String, *, name : String) : String
    path = File.join(directory, "#{name}.sock")
    if path.bytesize > SOCKET_PATH_LIMIT
      raise ArgumentError.new("socket path #{path} has #{path.bytesize} bytes, more than the #{SOCKET_PATH_LIMIT} " \
                              "a Unix socket address holds; set TMPDIR to a shorter directory")
    end
    path
  end
end
