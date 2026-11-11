{% skip_file unless flag?(:darwin) %}

require "c/fcntl"
require "c/sys/stat"
require "c/unistd"
require "random/secure"
require "../checked_directory/refusal"
require "../file_status"
require "../lib_directory"
require "../lib_system"
require "../trusted_directory"
require "./failure"
require "./owner"

module Tunnelgeist
  class Install
    # Checks the directories `install` writes in, and creates and writes
    # there, through `TrustedDirectory`: every directory from `/` down is
    # opened relative to the one above it and must pass `TrustPolicy` for
    # the owner, root for a real installation, its ACL included (RF5.6).
    # `install` writes as root, and a user who may write one of them could
    # swap what install writes for a link. Directories are created and files
    # written relative to the checked descriptor of the directory they go
    # in, never by path. The walk raises `CheckedDirectory::Refusal` naming
    # the directory it refuses.
    class Writer
      # The mode a directory `install` creates has until it belongs to the
      # owner.
      PRIVATE_DIRECTORY_MODE = 0o700
      # The mode a file `install` writes has until it belongs to the owner.
      PRIVATE_FILE_MODE = 0o600
      # The mode of a directory `install` creates once it belongs to the
      # owner.
      DIRECTORY_MODE = 0o755
      # Creates the temporary file a file is written through: only a new
      # file, never through a symbolic link.
      OPEN_TEMPORARY = LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL | LibC::O_NOFOLLOW | LibC::O_CLOEXEC

      # A writer that gives what it creates to *owner* and requires each
      # directory to be owned by root or *owner*.
      def initialize(@owner : Owner)
      end

      # Checks every directory from `/` down to *path* that exists; the walk
      # stops at the first name that does not, where `make_directories`
      # would create it.
      def check(path : String) : Nil
        directory = open_root
        begin
          Writer.names(path).each do |name|
            break unless directory.exists?(name)

            child = directory.open([name])
            directory.close
            directory = child
          end
        ensure
          directory.close
        end
      end

      # Checks every directory from `/` down to *path*, all of which must
      # exist.
      def check_existing(path : String) : Nil
        reach(path, create: false).close
      end

      # Creates the directories from `/` down to *path* that do not exist,
      # each in the checked directory above it, with mode `DIRECTORY_MODE`
      # and the owner.
      def make_directories(path : String) : Nil
        reach(path, create: true).close
      end

      # Whether something, even a broken link, is at *path*, whose
      # directory must exist.
      def exists?(path : String) : Bool
        directory = reach(File.dirname(path), create: false)
        begin
          directory.exists?(File.basename(path))
        ensure
          directory.close
        end
      end

      # Writes *path*, whose directory must exist, through a temporary file
      # beside it that the block fills, then gives it *mode* and the owner
      # and renames it over *path*, so *path* never holds a partial file.
      # The temporary file is created mode 0600 and the owner and mode are
      # set on its descriptor, so no one else can read it before *mode* is
      # set; it is removed when anything fails.
      def write(path : String, *, mode : Int32, & : IO ->) : Nil
        directory = reach(File.dirname(path), create: false)
        begin
          replace(directory, name: File.basename(path), mode: mode) { |file| yield file }
        ensure
          directory.close
        end
      end

      # The names of *path* from `/`.
      protected def self.names(path : String) : Array(String)
        path.split('/').reject!(&.empty?)
      end

      private def open_root : TrustedDirectory
        TrustedDirectory.open([] of String, owner: @owner.uid)
      end

      # The checked directory *path*, which the caller closes. A name that
      # does not exist is created when *create*, else refused as
      # `CheckedDirectory::Missing`.
      private def reach(path : String, *, create : Bool) : TrustedDirectory
        directory = open_root
        begin
          Writer.names(path).each do |name|
            make_directory(directory, name: name) if create && !directory.exists?(name)
            child = directory.open([name])
            directory.close
            directory = child
          end
        rescue error
          directory.close
          raise error
        end
        directory
      end

      # Creates the directory *name* in *parent*, mode 0700 at first, opens
      # it without following a symbolic link and checks that it is the
      # directory this process just created before it gives the descriptor
      # the owner and `DIRECTORY_MODE`. The caller opens it through the
      # walk, which checks it like any other.
      private def make_directory(parent : TrustedDirectory, *, name : String) : Nil
        path = File.join(parent.path, name)
        if LibDirectory.mkdirat(parent.fd, name, LibC::ModeT.new(PRIVATE_DIRECTORY_MODE)) != 0
          raise File::Error.from_errno("Unable to create directory", file: path)
        end

        fd = LibDirectory.openat(parent.fd, name, TrustedDirectory::OPEN_DIRECTORY)
        raise File::Error.from_errno("Unable to open directory", file: path) if fd < 0

        begin
          stat = uninitialized LibC::Stat
          raise File::Error.from_errno("Unable to examine directory", file: path) unless LibC.fstat(fd, pointerof(stat)) == 0
          status = FileStatus.of(stat)
          unless status.type.directory? && status.owner == LibSystem.geteuid
            raise Failure.new("#{path} is not the directory install created")
          end
          give(fd, path: path, mode: DIRECTORY_MODE)
        ensure
          LibC.close(fd)
        end
      end

      # Fills a temporary file in *directory* with the block and renames it
      # to *name*, as `write` describes.
      private def replace(directory : TrustedDirectory, *, name : String, mode : Int32, & : IO ->) : Nil
        temporary = "#{name}.#{Random::Secure.hex(8)}.tmp"
        temporary_path = File.join(directory.path, temporary)
        fd = LibDirectory.openat(directory.fd, temporary, OPEN_TEMPORARY, PRIVATE_FILE_MODE)
        raise File::Error.from_errno("Error opening file with mode 'wb'", file: temporary_path) if fd < 0

        begin
          file = IO::FileDescriptor.new(fd)
          begin
            yield file
            file.flush
            give(fd, path: temporary_path, mode: mode)
          ensure
            file.close
          end
          if LibDirectory.renameat(directory.fd, temporary, directory.fd, name) != 0
            raise File::Error.from_errno("Error renaming file", file: temporary_path, other: File.join(directory.path, name))
          end
        rescue error
          LibDirectory.unlinkat(directory.fd, temporary, 0)
          raise error
        end
      end

      # Gives the open *fd* of *path* the owner and *mode*.
      private def give(fd : Int32, *, path : String, mode : Int32) : Nil
        raise File::Error.from_errno("fchown", file: path) unless LibC.fchown(fd, @owner.uid, @owner.gid) == 0
        raise File::Error.from_errno("fchmod", file: path) unless LibC.fchmod(fd, LibC::ModeT.new(mode)) == 0
      end
    end
  end
end
