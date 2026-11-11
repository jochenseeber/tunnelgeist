require "../../../src/tunnelgeist/config/error"
require "../../../src/tunnelgeist/config/trusted_directory"

# The configuration loader opens every file through the directories from `/`
# down, and refuses one any of them does not pass; a test that loads files
# from the temporary directory needs `$TMPDIR` and all above it to pass too.
module TunnelgeistTrustedTemporaryDirectory
  extend self

  # Raises with what to change when the configuration walk refuses
  # *directory* or a directory above it for the trusted user *owner*.
  def check_trusted(directory : String, *, owner : UInt32) : Nil
    names = directory.split('/').reject!(&.empty?)
    Tunnelgeist::Config::TrustedDirectory.open(names, owner: owner) { }
  rescue error : Tunnelgeist::Config::Error
    raise "the configuration loader refuses the temporary directory #{directory} (#{error.message}); set TMPDIR " \
          "to a directory that only root or you own, no one else may write and no ACL lets anyone else write, " \
          "down from /, such as macOS's own per-user one"
  end
end
