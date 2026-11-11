require "../../test_helper"
require "../../../src/tunnelgeist/install/failure"
require "../../../src/tunnelgeist/install/owner"
require "../../../src/tunnelgeist/install/writer"
require "../../../src/tunnelgeist/lib_system"
require "../support/temporary_directory"
require "../support/trusted_temporary_directory"

# What `Install::Writer` reports when it cannot create or remove the
# temporary file it writes through, over real directories below the
# temporary directory, whose own ancestors it walks through too. The tests
# run as a user, so a directory of mode 0555 refuses to take or give up a
# file, which it would not for root.
describe TunnelgeistInstallWriter do
  {% if flag?(:darwin) %}
    include TunnelgeistTemporaryDirectory

    alias Install = Tunnelgeist::Install

    # A writer for the user running the tests.
    def writer : Install::Writer
      Install::Writer.new(Install::Owner.new(uid: Tunnelgeist::LibSystem.geteuid, gid: Tunnelgeist::LibSystem.getegid))
    end

    # Runs the block with a new directory the walk accepts, mode 0755, and
    # its subdirectory `out`, mode 0755, which it may make read-only; `out`
    # is made writable again before both are removed.
    def with_directory(&)
      with_temporary_directory do |directory|
        File.chmod(directory, 0o755)
        TunnelgeistTrustedTemporaryDirectory.check_trusted(directory, owner: Tunnelgeist::LibSystem.geteuid)
        target = File.join(directory, "out")
        Dir.mkdir(target, 0o755)
        File.chmod(target, 0o755)
        begin
          yield target
        ensure
          File.chmod(target, 0o755)
        end
      end
    end

    test "write says which temporary file it cannot create and why" do
      with_directory do |directory|
        File.chmod(directory, 0o555)
        path = File.join(directory, "binary")

        message = raised(Install::Failure) { writer.write(path, mode: 0o755, &.print("x")) }.message.to_s

        assert(message.starts_with?("#{path}."))
        assert(message.ends_with?(".tmp: cannot create the temporary file: Permission denied"))
        assert(Dir.children(directory).empty?)
      end
    end

    test "write says when it cannot remove the temporary file after a failure" do
      with_directory do |directory|
        path = File.join(directory, "binary")
        cause = IO::Error.new("the copy failed")

        failure = raised(Install::Failure) do
          writer.write(path, mode: 0o755) do
            File.chmod(directory, 0o555)
            raise cause
          end
        end
        left = Dir.children(directory)

        assert(left.size == 1)
        assert(failure.message == "the copy failed; the temporary file #{File.join(directory, left.first)} could not " \
                                  "be removed: Permission denied")
        assert(failure.cause.same?(cause))
        assert(!File.exists?(path))
      end
    end

    test "write removes the temporary file after a failure and raises the failure itself" do
      with_directory do |directory|
        path = File.join(directory, "binary")

        error = raised(IO::Error) { writer.write(path, mode: 0o755) { raise IO::Error.new("the copy failed") } }

        assert(error.message == "the copy failed")
        assert(Dir.children(directory).empty?)
      end
    end
  {% end %}
end
