require "../../../src/tunnelgeist/config/directory"
require "../../../src/tunnelgeist/config/directory/missing"
require "../../../src/tunnelgeist/config/error"
require "../../../src/tunnelgeist/config/file_status"
require "../../../src/tunnelgeist/config/trust_policy"
require "../../../src/tunnelgeist/config/trusted_file"
require "./outside_temporary_directory"

# A configuration directory for the specs of the loader. It applies
# `TrustPolicy` to what `File.info` says about each file and each directory
# below the temporary directory, but leaves the directories at and above the
# temporary directory alone, so a spec depends on nothing outside the
# directory it made. It reads no ACL. *statuses* stand in for what `fstat`
# says about the paths they name, such as another owner, which a spec could
# not give a file itself.
class TunnelgeistFakeDirectory < Tunnelgeist::Config::Directory
  alias Config = Tunnelgeist::Config

  # The path of the directory.
  getter path : String

  def initialize(@path : String, *, @owner : UInt32, @statuses : Hash(String, Config::FileStatus),
                 @base : String)
  end

  # An `open_directory` for `Config::Loader` that opens directories at or
  # below *base*, the real path of the temporary directory unless given,
  # with *statuses* standing in for the status of the paths they name.
  def self.opener(*, statuses : Hash(String, Config::FileStatus) = {} of String => Config::FileStatus,
                  base : String = File.realpath(Dir.tempdir)) : Array(String), UInt32 -> Config::Directory
    ->(names : Array(String), owner : UInt32) do
      new("/", owner: owner, statuses: statuses, base: base).open(names).as(Config::Directory)
    end
  end

  def open(names : Array(String)) : Config::Directory
    path = @path
    names.each do |name|
      path = path_of(name, parent: path)
      check_directory(path) if below_base?(path)
    end
    unless path == @base || below_base?(path)
      raise TunnelgeistOutsideTemporaryDirectory.new("the fake directory serves only #{@base} and below, not #{path}")
    end
    TunnelgeistFakeDirectory.new(path, owner: @owner, statuses: @statuses, base: @base)
  end

  def read(name : String) : Config::TrustedFile
    path = path_of(name, parent: @path)
    info = File.info?(path, follow_symlinks: false) || raise Config::Directory::Missing.new(file: path)
    raise Config::Error.new("must be a regular file, not a symbolic link", file: path) if info.type.symlink?
    problem = Config::TrustPolicy.file_problem(status(path, info: info), owner: @owner)
    raise Config::Error.new(problem, file: path) if problem

    Config::TrustedFile.new(path: path, text: File.read(path))
  end

  def names : Array(String)
    Dir.children(@path)
  end

  def close : Nil
  end

  private def check_directory(path : String) : Nil
    info = File.info?(path, follow_symlinks: false) || raise Config::Directory::Missing.new(file: path)
    raise Config::Error.new("must be a directory, not a symbolic link", file: path) if info.type.symlink?
    problem = Config::TrustPolicy.directory_problem(status(path, info: info), owner: @owner)
    raise Config::Error.new(problem, file: path) if problem
  end

  private def status(path : String, *, info : File::Info) : Config::FileStatus
    @statuses[path]? || Config::FileStatus.new(type: info.type, owner: info.owner_id.to_u32,
      mode: info.permissions.value.to_u16, size: info.size)
  end

  private def below_base?(path : String) : Bool
    path.starts_with?("#{@base}/")
  end

  private def path_of(name : String, *, parent : String) : String
    parent == "/" ? "/#{name}" : "#{parent}/#{name}"
  end
end
