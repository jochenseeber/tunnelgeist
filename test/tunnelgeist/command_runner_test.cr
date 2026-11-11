require "../test_helper"
require "../../src/tunnelgeist/command_runner"

# The runner of UC4 hands a child no descriptor but standard input, output and
# error; it runs the system's programs (`/bin/sh`, `/bin/test`, `/bin/cat`).
describe TunnelgeistCommandRunner do
  {% if flag?(:darwin) %}
    alias CommandRunner = Tunnelgeist::CommandRunner

    # The exit status of `/bin/test -e` on descriptor *fd* in the child.
    def exists_in_child?(fd : Int32) : Int32
      CommandRunner.run(["/bin/test", "-e", "/dev/fd/#{fd}"]).exit_status
    end

    test "a descriptor without close-on-exec is absent in the child" do
      reader, writer = IO.pipe
      begin
        writer.close_on_exec = false

        assert(exists_in_child?(writer.fd) == 1)
      ensure
        reader.close
        writer.close
      end
    end

    test "the probe sees an open descriptor in the child" do
      assert(exists_in_child?(2) == 0)
    end

    test "success? is true only for exit status 0" do
      assert(CommandRunner.run(["/usr/bin/true"]).success?)
      assert(!CommandRunner.run(["/usr/bin/false"]).success?)
    end

    test "input reaches the standard input of the child" do
      result = CommandRunner.run(["/bin/cat"], input: "hello")

      assert(result.success?)
      assert(result.output == "hello")
    end

    test "CommandRunner.default returns the exit status, the standard output and the standard error" do
      run = CommandRunner.default

      assert(run.call(["/usr/bin/true"]) == CommandRunner::Result.new(exit_status: 0, output: "", error: ""))
      assert(run.call(["/bin/sh", "-c", "echo out; echo oops >&2; exit 3"]) ==
             CommandRunner::Result.new(exit_status: 3, output: "out\n", error: "oops\n"))
    end

    test "CommandRunner.default runs with an empty environment" do
      run = CommandRunner.default
      ENV["TUNNELGEIST_TEST_MARK"] = "set"
      begin
        result = run.call(["/bin/sh", "-c", "echo \"[$HOME][$TUNNELGEIST_TEST_MARK]\" >&2"])
        assert(result == CommandRunner::Result.new(exit_status: 0, output: "", error: "[][]\n"))
      ensure
        ENV.delete("TUNNELGEIST_TEST_MARK")
      end
    end
  {% end %}
end
