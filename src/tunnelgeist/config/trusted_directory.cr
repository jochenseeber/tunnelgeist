{% skip_file unless flag?(:darwin) %}

require "c/dirent"
require "c/fcntl"
require "c/sys/stat"
require "c/unistd"
require "../lib_system"
require "./acl_entry"
require "./acl_permissions"
require "./directory"
require "./directory/missing"
require "./error"
require "./file_status"
require "./lib_acl"
require "./lib_directory"
require "./trust_policy"
require "./trusted_file"

module Tunnelgeist
  struct Config
    # An open directory every directory from `/` down to it has been checked
    # in (RF5.1): each step opens the next name relative to the descriptor
    # of the last, never following a symbolic link, and checks the opened
    # descriptor's `fstat` and ACL with `TrustPolicy` before it goes on. A
    # file is read from the descriptor that passed the checks, so no rename
    # or link swapped in between the check and the read changes what is
    # read.
    #
    # Every refusal is a `Config::Error` naming the path walked up to the
    # object that failed, `Missing` when it does not exist. *owner* is the
    # trusted user besides root: the owner every file must have.
    class TrustedDirectory < Directory
      # Opens each directory of the walk: no symbolic link, nothing but a
      # directory.
      OPEN_DIRECTORY = LibC::O_RDONLY | LibDirectory::O_DIRECTORY | LibC::O_NOFOLLOW | LibC::O_CLOEXEC
      # Opens a file to read: no symbolic link, and without waiting for a
      # writer, which opening a FIFO would before the check refuses it.
      OPEN_FILE = LibC::O_RDONLY | LibC::O_NOFOLLOW | LibC::O_CLOEXEC | LibC::O_NONBLOCK
      # How much of a file one `read` asks for.
      CHUNK_SIZE = 16_384

      # The path walked to the directory, from `/`.
      getter path : String
      # The trusted user besides root.
      getter owner : UInt32

      protected def initialize(@fd : Int32, *, @path : String, @owner : UInt32)
      end

      # The directory reached from `/` through the plain names *names*,
      # which the caller closes.
      def self.open(names : Array(String), *, owner : UInt32) : TrustedDirectory
        root(owner: owner).walk(names)
      end

      # Runs the block with the directory reached from `/` through the plain
      # names *names* and closes it afterwards.
      def self.open(names : Array(String), *, owner : UInt32, &)
        directory = open(names, owner: owner)
        begin
          yield directory
        ensure
          directory.close
        end
      end

      # :inherit:
      def open(names : Array(String)) : Directory
        TrustedDirectory.new(duplicate, path: @path, owner: @owner).walk(names)
      end

      # The text of the file *name* in this directory: a regular file owned
      # by the owner that no one else may write and no ACL lets anyone else
      # write, of at most `TrustPolicy::MAX_FILE_SIZE` bytes.
      def read(name : String) : TrustedFile
        path = path_of(name)
        fd = LibDirectory.openat(@fd, plain(name), OPEN_FILE)
        raise open_error(name, directory: false) if fd < 0

        begin
          status = TrustedDirectory.status(fd, path: path)
          problem = TrustPolicy.file_problem(status, owner: @owner) || TrustedDirectory.acl_problem(fd, status: status, path: path)
          raise Error.new(problem, file: path) if problem
          text = read_text(fd, path: path)
        ensure
          LibC.close(fd)
        end
        TrustedFile.new(path: path, text: text)
      end

      # The names in this directory, `.` and `..` left out, in the order
      # the directory gives them.
      def names : Array(String)
        copy = duplicate
        stream = LibDirectory.fdopendir(copy)
        if stream.null?
          message = Errno.value.message
          LibC.close(copy)
          raise Error.new("cannot be listed: #{message}", file: @path)
        end

        names = [] of String
        begin
          # The copy shares the read position with this directory's
          # descriptor, which an earlier listing moved.
          LibC.rewinddir(stream)
          loop do
            Errno.value = Errno::NONE
            entry = LibC.readdir(stream)
            if entry.null?
              errno = Errno.value
              raise Error.new("cannot be listed: #{errno.message}", file: @path) unless errno.none?
              break
            end
            name = String.new(entry.value.d_name.to_unsafe, entry.value.d_namlen)
            names << name unless name.in?(".", "..")
          end
        ensure
          LibC.closedir(stream)
        end
        names
      end

      # The path of *name* in this directory.
      protected def path_of(name : String) : String
        @path == "/" ? "/#{name}" : "#{@path}/#{name}"
      end

      # Closes the directory's descriptor.
      def close : Nil
        LibC.close(@fd)
      end

      # The directory reached from this one through *names*. This one is
      # closed, also when the walk fails, so the caller holds only what it
      # gets back.
      protected def walk(names : Array(String)) : TrustedDirectory
        current = self
        names.each do |name|
          parent = current
          begin
            current = parent.child(name)
          ensure
            parent.close
          end
        end
        current
      end

      # The checked directory *name* in this one.
      protected def child(name : String) : TrustedDirectory
        fd = LibDirectory.openat(@fd, plain(name), OPEN_DIRECTORY)
        raise open_error(name, directory: true) if fd < 0

        TrustedDirectory.checked(fd, path: path_of(name), owner: @owner)
      end

      # The checked root directory.
      protected def self.root(*, owner : UInt32) : TrustedDirectory
        fd = LibC.open("/", OPEN_DIRECTORY)
        raise Error.new("cannot be opened: #{Errno.value.message}", file: "/") if fd < 0

        checked(fd, path: "/", owner: owner)
      end

      # The directory open on *fd*, after its status and ACL passed
      # `TrustPolicy`; closes *fd* when they do not.
      protected def self.checked(fd : Int32, *, path : String, owner : UInt32) : TrustedDirectory
        begin
          status = status(fd, path: path)
          problem = TrustPolicy.directory_problem(status, owner: owner) || acl_problem(fd, status: status, path: path)
          raise Error.new(problem, file: path) if problem
        rescue error
          LibC.close(fd)
          raise error
        end
        new(fd, path: path, owner: owner)
      end

      # The refusal of an `openat` of *name* in this directory that failed
      # with `errno`. `O_NOFOLLOW` fails with `ELOOP` on a symbolic link,
      # but `O_DIRECTORY` takes precedence with `ENOTDIR`, so a link in
      # place of a directory is told apart by the status of the name.
      private def open_error(name : String, *, directory : Bool) : Error
        errno = Errno.value
        path = path_of(name)
        noun = directory ? "a directory" : "a regular file"
        case errno
        when Errno::ENOENT
          Missing.new(file: path)
        when Errno::ELOOP
          Error.new("must be #{noun}, not a symbolic link", file: path)
        when Errno::ENOTDIR
          Error.new(symbolic_link?(name) ? "must be #{noun}, not a symbolic link" : "must be #{noun}", file: path)
        else
          Error.new("cannot be opened: #{errno.message}", file: path)
        end
      end

      # Whether *name* in this directory is a symbolic link.
      private def symbolic_link?(name : String) : Bool
        stat = uninitialized LibC::Stat
        return false unless LibDirectory.fstatat(@fd, name, pointerof(stat), LibC::AT_SYMLINK_NOFOLLOW) == 0

        FileStatus.of(stat).type.symlink?
      end

      # The status of the open *fd*.
      protected def self.status(fd : Int32, *, path : String) : FileStatus
        stat = uninitialized LibC::Stat
        raise Error.new("cannot be examined: #{Errno.value.message}", file: path) unless LibC.fstat(fd, pointerof(stat)) == 0

        FileStatus.of(stat)
      end

      # Why the ACL of the open *fd* refuses it, nil when it does not.
      protected def self.acl_problem(fd : Int32, *, status : FileStatus, path : String) : String?
        TrustPolicy.acl_problem(acl_entries(fd, path: path), owner: status.owner)
      end

      # The entries of the extended ACL of the open *fd*; none when it has
      # no ACL or its file system keeps none.
      private def self.acl_entries(fd : Int32, *, path : String) : Array(AclEntry)
        entries = [] of AclEntry
        acl = LibAcl.acl_get_fd_np(fd, LibAcl::ACL_TYPE_EXTENDED)
        if acl.null?
          errno = Errno.value
          raise Error.new("cannot read its ACL: #{errno.message}", file: path) unless errno.enoent? || errno.eopnotsupp?
          return entries
        end

        begin
          entry = LibAcl::AclEntryT.null
          id = LibAcl::ACL_FIRST_ENTRY
          while LibAcl.acl_get_entry(acl, id, pointerof(entry)) == 0
            entries << acl_entry(entry, path: path)
            id = LibAcl::ACL_NEXT_ENTRY
          end
          # The end of the list is `EINVAL`; anything else would leave
          # entries unread.
          errno = Errno.value
          raise Error.new("cannot read its ACL: #{errno.message}", file: path) unless errno.einval?
        ensure
          LibAcl.acl_free(acl)
        end
        entries
      end

      private def self.acl_entry(entry : LibAcl::AclEntryT, *, path : String) : AclEntry
        tag = 0
        mask = 0_u64
        unless LibAcl.acl_get_tag_type(entry, pointerof(tag)) == 0 && LibAcl.acl_get_permset_mask_np(entry, pointerof(mask)) == 0
          raise Error.new("cannot read its ACL: #{Errno.value.message}", file: path)
        end

        AclEntry.new(allow: tag == LibAcl::ACL_EXTENDED_ALLOW, uid: qualifier_uid(entry),
          permissions: AclPermissions.new(mask))
      end

      # The uid the qualifier of *entry* names; nil for a group or one the
      # directory service does not know.
      private def self.qualifier_uid(entry : LibAcl::AclEntryT) : UInt32?
        qualifier = LibAcl.acl_get_qualifier(entry)
        return if qualifier.null?

        begin
          id = 0_u32
          type = -1
          found = LibSystem.mbr_uuid_to_id(qualifier.as(UInt8*), pointerof(id), pointerof(type)) == 0
          found && type == LibSystem::ID_TYPE_UID ? id : nil
        ensure
          LibAcl.acl_free(qualifier)
        end
      end

      # A new descriptor for this directory, which the caller closes.
      private def duplicate : Int32
        fd = LibDirectory.dup(@fd)
        raise Error.new("cannot be duplicated: #{Errno.value.message}", file: @path) if fd < 0
        fd
      end

      # The text of the open file *fd*, which must stay within
      # `TrustPolicy::MAX_FILE_SIZE` bytes, which its status said it does,
      # while it is read.
      private def read_text(fd : Int32, *, path : String) : String
        text = IO::Memory.new
        chunk = Bytes.new(CHUNK_SIZE)
        loop do
          count = LibC.read(fd, chunk, chunk.size)
          if count < 0
            errno = Errno.value
            next if errno.eintr?
            raise Error.new("cannot be read: #{errno.message}", file: path)
          end
          break if count == 0
          text.write(chunk[0, count])
          raise Error.new(TrustPolicy::TOO_LARGE, file: path) if text.size > TrustPolicy::MAX_FILE_SIZE
        end
        text.to_s
      end

      # *name*, which must be one plain path component: not empty, `.` or
      # `..`, and without `/` or a NUL byte.
      private def plain(name : String) : String
        name.check_no_null_byte
        if name.empty? || name.in?(".", "..") || name.includes?('/')
          raise ArgumentError.new("not a plain file name: #{name.inspect}")
        end
        name
      end
    end
  end
end
