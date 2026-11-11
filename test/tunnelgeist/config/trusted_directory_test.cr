require "c/sys/stat"
require "system/user"
require "../../test_helper"
require "../../../src/tunnelgeist/config/error"
require "../../../src/tunnelgeist/config/trusted_directory"
require "../../../src/tunnelgeist/config/directory/missing"
require "../../../src/tunnelgeist/lib_system"
require "../support/trusted_temporary_directory"
require "../support/temporary_directory"

# The walk from `/` to a configuration file (RF5.1, RF5.3) over real files
# below the temporary directory, whose own ancestors it walks through too,
# with ACLs set by `/bin/chmod +a`.
describe Tunnelgeist::Config::TrustedDirectory do
  {% if flag?(:darwin) %}
    include TunnelgeistTemporaryDirectory

    alias Config = Tunnelgeist::Config
    alias TrustedDirectory = Tunnelgeist::Config::TrustedDirectory

    # The uid running the tests, the trusted owner of what they create.
    def euid : UInt32
      Tunnelgeist::LibSystem.geteuid
    end

    # Runs the block with a new temporary directory the walk accepts, mode
    # 0755.
    def with_directory(&)
      with_temporary_directory do |directory|
        File.chmod(directory, 0o755)
        TunnelgeistTrustedTemporaryDirectory.check_trusted(directory, owner: euid)
        yield directory
      end
    end

    # Writes *content* to *name* below *directory* with mode 0644, creating
    # its directories with mode 0755, and returns the path.
    def write(directory : String, *, name : String, content : String = "{}") : String
      path = File.join(directory, name)
      parent = File.dirname(path)
      Dir.mkdir_p(parent)
      File.chmod(parent, 0o755)
      File.write(path, content)
      File.chmod(path, 0o644)
      path
    end

    # The components of *path*.
    def names(path : String) : Array(String)
      path.split('/').reject!(&.empty?)
    end

    # The text of the file at *path*, read through the walk.
    def read(path : String, *, owner : UInt32 = euid) : String
      TrustedDirectory.open(names(File.dirname(path)), owner: owner) { |directory| directory.read(File.basename(path)).text }
    end

    # The error reading the file at *path* through the walk raises.
    def read_error(path : String) : Config::Error
      raised(Config::Error) { read(path) }
    end

    # Adds the ACL entry *entry* to *path* with `chmod +a`.
    def add_acl(path : String, *, entry : String) : Nil
      status = Process.run("/bin/chmod", ["+a", entry, path], error: Process::Redirect::Inherit)
      raise "chmod +a #{entry.inspect} #{path} failed" unless status.success?
    end

    test "read reads a file from a directory below the temporary directory" do
      with_directory do |directory|
        path = write(directory, name: "a/b/config.json", content: %({"x": 1}))

        assert(read(path) == %({"x": 1}))
      end
    end

    test "read names the path it read the file at" do
      with_directory do |directory|
        path = write(directory, name: "a/config.json")

        file = TrustedDirectory.open(names(File.dirname(path)), owner: euid) { |parent| parent.read("config.json") }

        assert(file.path == path)
      end
    end

    test "read refuses a symbolic link in place of a directory above the file" do
      with_directory do |directory|
        write(directory, name: "real/b/config.json")
        link = File.join(directory, "link")
        File.symlink(File.join(directory, "real"), link)

        error = read_error(File.join(link, "b", "config.json"))

        assert(error.file == link)
        assert(error.message == "#{link}: must be a directory, not a symbolic link")
      end
    end

    test "read refuses a symbolic link in place of the file" do
      with_directory do |directory|
        target = write(directory, name: "real.json")
        link = File.join(directory, "config.json")
        File.symlink(target, link)

        assert(read_error(link).message == "#{link}: must be a regular file, not a symbolic link")
      end
    end

    test "read refuses a file below a directory the group or others may write, however far above" do
      [0o775, 0o757, 0o1777].each do |mode|
        with_directory do |directory|
          path = write(directory, name: "a/b/c/config.json")
          writable = File.join(directory, "a")
          File.chmod(writable, mode)

          error = read_error(path)

          assert(error.file == writable)
          assert(error.message == "#{writable}: directory must be writable only by its owner, not mode #{"%04o" % mode}")
        end
      end
    end

    test "read refuses a file below a directory of another owner" do
      with_directory do |directory|
        path = write(directory, name: "config.json")
        owner = euid + 1

        error = raised(Config::Error) { read(path, owner: owner) }

        assert(directory == error.file || directory.starts_with?("#{error.file}/"))
        assert(error.reason == "directory must be owned by root or uid #{owner}, not uid #{euid}")
      end
    end

    test "read refuses a file in /private/tmp, which everyone may write" do
      error = read_error("/private/tmp/tunnelgeist-config.json")

      assert(error.message == "/private/tmp: directory must be writable only by its owner, not mode 1777")
    end

    test "read refuses a path through /etc, a symbolic link" do
      assert(read_error("/etc/hosts").message == "/etc: must be a directory, not a symbolic link")
    end

    test "read refuses a missing file or directory with Missing" do
      with_directory do |directory|
        missing_file = File.join(directory, "config.json")
        missing_directory = File.join(directory, "d")

        assert(raised(Config::Directory::Missing) { read(missing_file) }.message == "#{missing_file}: does not exist")
        assert(raised(Config::Directory::Missing) { read(File.join(missing_directory, "config.json")) }.message ==
               "#{missing_directory}: does not exist")
      end
    end

    test "read refuses a file in place of a directory" do
      with_directory do |directory|
        file = write(directory, name: "a")

        assert(read_error(File.join(file, "config.json")).message == "#{file}: must be a directory")
      end
    end

    test "read refuses a FIFO without waiting for a writer" do
      with_directory do |directory|
        fifo = File.join(directory, "config.json")
        raise "mkfifo #{fifo} failed" unless LibC.mkfifo(fifo, 0o644) == 0

        assert(read_error(fifo).message == "#{fifo}: must be a regular file")
      end
    end

    test "read refuses a file over 1 MiB and reads one of exactly 1 MiB" do
      with_directory do |directory|
        exact = write(directory, name: "exact.json", content: "x" * 1_048_576)
        large = write(directory, name: "large.json", content: "x" * 1_048_577)

        assert(read(exact).bytesize == 1_048_576)
        assert(read_error(large).message == "#{large}: must be at most 1 MiB (1048576 bytes)")
      end
    end

    test "read refuses a file whose ACL lets everyone write" do
      with_directory do |directory|
        path = write(directory, name: "config.json")
        add_acl(path, entry: "everyone allow write")

        assert(read_error(path).message == "#{path}: grants write access through its ACL")
      end
    end

    test "read refuses a file whose ACL lets a group append or another user change its owner" do
      ["staff allow append", "user:nobody allow chown", "everyone allow delete", "everyone allow writeattr"].each do |entry|
        with_directory do |directory|
          path = write(directory, name: "config.json")
          add_acl(path, entry: entry)

          assert(read_error(path).message == "#{path}: grants write access through its ACL")
        end
      end
    end

    test "read refuses a directory whose ACL lets everyone add files, and a file that inherited that grant" do
      with_directory do |directory|
        shared = File.join(directory, "shared")
        Dir.mkdir(shared, 0o755)
        add_acl(shared, entry: "everyone allow add_file,file_inherit,directory_inherit")
        path = write(directory, name: "shared/config.json")

        assert(read_error(path).message == "#{shared}: grants write access through its ACL")

        # With the directory's own entry gone, the file still carries the
        # entry it inherited.
        status = Process.run("/bin/chmod", ["-N", shared], error: Process::Redirect::Inherit)
        raise "chmod -N #{shared} failed" unless status.success?

        assert(read_error(path).message == "#{path}: grants write access through its ACL")
      end
    end

    test "read refuses a directory whose ACL lets everyone delete what it holds" do
      with_directory do |directory|
        path = write(directory, name: "a/config.json")
        add_acl(File.dirname(path), entry: "everyone allow delete_child")

        assert(read_error(path).message == "#{File.dirname(path)}: grants write access through its ACL")
      end
    end

    test "read accepts ACLs that grant reading or listing, deny writing, or grant the owner" do
      with_directory do |directory|
        path = write(directory, name: "a/config.json", content: "ok")
        add_acl(File.dirname(path), entry: "everyone allow list,search,readattr")
        add_acl(File.dirname(path), entry: "everyone deny add_file,delete_child")
        add_acl(path, entry: "everyone allow read")
        add_acl(path, entry: "staff deny write")
        add_acl(path, entry: "user:#{System::User.find_by(id: euid.to_s).username} allow write,chown")

        assert(read(path) == "ok")
      end
    end

    test "names lists a directory's entries without . and .., again on a second call" do
      with_directory do |directory|
        write(directory, name: "d/b.json")
        write(directory, name: "d/.a.json")
        Dir.mkdir(File.join(directory, "d", "sub"))

        TrustedDirectory.open(names(File.join(directory, "d")), owner: euid) do |parent|
          assert(parent.names.sort == [".a.json", "b.json", "sub"])
          assert(parent.names.sort == [".a.json", "b.json", "sub"])
        end
      end
    end

    test "descend opens a directory below a checked one with the same checks and leaves that one open" do
      with_directory do |directory|
        write(directory, name: "a/b/c.json", content: "c")
        write(directory, name: "a/d.json", content: "d")
        File.chmod(File.join(directory, "a", "b"), 0o777)

        TrustedDirectory.open(names(File.join(directory, "a")), owner: euid) do |parent|
          error = raised(Config::Error) { parent.descend(["b"]) { } }
          assert(error.message == "#{directory}/a/b: directory must be writable only by its owner, not mode 0777")
          assert(parent.descend([] of String, &.read("d.json").text) == "d")
          assert(parent.read("d.json").text == "d")
        end
      end
    end
  {% end %}
end
