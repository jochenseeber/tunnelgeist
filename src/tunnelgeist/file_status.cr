{% skip_file unless flag?(:darwin) %}

require "c/sys/stat"

module Tunnelgeist
  # What `TrustPolicy` judges of an open file's `fstat`: its type, its
  # owner, its permission bits (setuid, setgid and sticky included) and
  # its size in bytes.
  record FileStatus, type : File::Type, owner : UInt32, mode : UInt16, size : Int64 do
    # The status `fstat` filled into *stat*.
    def self.of(stat : LibC::Stat) : FileStatus
      new(type: type_of(stat.st_mode), owner: stat.st_uid.to_u32, mode: (stat.st_mode & 0o7777).to_u16,
        size: stat.st_size.to_i64)
    end

    private def self.type_of(mode : LibC::ModeT) : File::Type
      case mode & LibC::S_IFMT
      when LibC::S_IFREG  then File::Type::File
      when LibC::S_IFDIR  then File::Type::Directory
      when LibC::S_IFLNK  then File::Type::Symlink
      when LibC::S_IFIFO  then File::Type::Pipe
      when LibC::S_IFSOCK then File::Type::Socket
      when LibC::S_IFCHR  then File::Type::CharacterDevice
      when LibC::S_IFBLK  then File::Type::BlockDevice
      else                     File::Type::Unknown
      end
    end
  end
end
