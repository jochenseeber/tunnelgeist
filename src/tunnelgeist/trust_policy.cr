{% skip_file unless flag?(:darwin) %}

require "./acl_entry"
require "./acl_permissions"
require "./file_status"

module Tunnelgeist
  # What makes a configuration file and every directory above it
  # trustworthy (CC2): the daemon reads them as root, and `install` writes
  # the daemon, its configuration and its property list into such
  # directories as root, so anything another user could write, or replace,
  # would let that user widen what root does. Each method returns why the
  # object is refused, nil when it is not; `TrustedDirectory` applies them
  # to what it opens.
  module TrustPolicy
    # The permission bits that let someone other than the owner write.
    WRITABLE_BY_OTHERS = 0o022_u16
    # The largest configuration file read, in bytes.
    MAX_FILE_SIZE = 1_048_576
    # Why a file larger than `MAX_FILE_SIZE` is refused.
    TOO_LARGE = "must be at most 1 MiB (#{MAX_FILE_SIZE} bytes)"
    # Why an object whose ACL lets another principal change it is refused.
    ACL_WRITE = "grants write access through its ACL"
    # The ACL permissions that only read an object or, on a directory,
    # list and search it. Any other right, a generic one or one this list
    # does not know included, may change it.
    ACL_READ_ONLY = AclPermissions::ReadData | AclPermissions::Execute | AclPermissions::ReadAttributes |
                    AclPermissions::ReadExtattributes | AclPermissions::ReadSecurity | AclPermissions::Synchronize

    # Why a directory with *status* may not lead to a configuration file
    # or hold what `install` writes: it must be a directory owned by root or
    # *owner*, the trusted user besides root, that no one else may write.
    def self.directory_problem(status : FileStatus, *, owner : UInt32) : String?
      if !status.type.directory?
        "must be a directory"
      elsif status.owner != 0 && status.owner != owner
        "directory must be owned by #{owner == 0 ? "root" : "root or uid #{owner}"}, not uid #{status.owner}"
      elsif writable_by_others?(status)
        "directory must be writable only by its owner, not mode #{mode_text(status)}"
      end
    end

    # Why a configuration file with *status* may not be read: it must be a
    # regular file owned by *owner* that no one else may write, of at most
    # `MAX_FILE_SIZE` bytes.
    def self.file_problem(status : FileStatus, *, owner : UInt32) : String?
      if !status.type.file?
        "must be a regular file"
      elsif status.owner != owner
        "must be owned by uid #{owner}, not uid #{status.owner}"
      elsif writable_by_others?(status)
        "must be writable only by its owner, not mode #{mode_text(status)}"
      elsif status.size > MAX_FILE_SIZE
        TOO_LARGE
      end
    end

    # Why an object owned by *owner* with the ACL *entries* is refused: an
    # entry that allows anyone but the owner, a group included, any right
    # outside `ACL_READ_ONLY`. Entries the object inherited count like its
    # own; denials and grants to read or list do not matter.
    def self.acl_problem(entries : Array(AclEntry), *, owner : UInt32) : String?
      ACL_WRITE if entries.any? { |entry| entry.allow && entry.uid != owner && writes?(entry.permissions) }
    end

    private def self.writes?(permissions : AclPermissions) : Bool
      permissions.value & ~ACL_READ_ONLY.value != 0
    end

    private def self.writable_by_others?(status : FileStatus) : Bool
      status.mode & WRITABLE_BY_OTHERS != 0
    end

    private def self.mode_text(status : FileStatus) : String
      "%04o" % status.mode
    end
  end
end
