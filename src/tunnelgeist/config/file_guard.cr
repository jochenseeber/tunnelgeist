{% skip_file unless flag?(:darwin) %}

require "./error"

module Tunnelgeist
  struct Config
    # The ownership and mode check of every configuration file (CC2): the
    # daemon reads them as root, so a file another user could write, or a
    # link that could point anywhere, would let that user widen what root
    # does.
    module FileGuard
      # The permission bits that let someone other than the owner write.
      WRITABLE_BY_OTHERS = File::Permissions::GroupWrite | File::Permissions::OtherWrite

      # Raises `Config::Error` naming the path and the failed condition
      # unless *path* is a regular file, not a symbolic link, owned by
      # *owner* and writable by no one else, and its directory is a
      # directory, not a symbolic link, with the same owner and mode rule.
      def self.check(path : String, *, owner : UInt32) : Nil
        check_entry(path, type: File::Type::File, owner: owner)
        check_entry(File.dirname(path), type: File::Type::Directory, owner: owner)
      end

      private def self.check_entry(path : String, *, type : File::Type, owner : UInt32) : Nil
        info = File.info(path, follow_symlinks: false)
        noun = type.file? ? "a regular file" : "a directory"
        if info.type.symlink?
          raise Error.new("must be #{noun}, not a symbolic link", file: path)
        elsif info.type != type
          raise Error.new("must be #{noun}", file: path)
        end

        actual = info.owner_id.to_u32
        raise Error.new("must be owned by uid #{owner}, not uid #{actual}", file: path) unless actual == owner

        unless (info.permissions & WRITABLE_BY_OTHERS).none?
          raise Error.new("must be writable only by its owner, not mode #{"%04o" % info.permissions.value}", file: path)
        end
      rescue error : File::NotFoundError
        raise Error.new("does not exist", file: path, cause: error)
      rescue error : File::Error
        raise Error.new("cannot be examined: #{error.os_error.try(&.message) || error.message}", file: path, cause: error)
      end
    end
  end
end
