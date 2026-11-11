require "../test_helper"
require "../../src/tunnelgeist/command_runner"

# The runner of UC4 hands a child no descriptor but standard input, output and
# error, and bounds its time, its output and how many run at once (RF2); it
# runs the system's programs (`/bin/sh`, `/bin/test`, `/bin/cat`,
# `/bin/sleep`, `/usr/bin/yes`, `/usr/bin/head`).
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

    # The process id the shell prints before it becomes `/bin/sleep 30`.
    def sleeper_pid(result : CommandRunner::Result) : Int64
      result.output.strip.to_i64
    end

    test "a program that runs past the time limit is stopped with TERM, reaped and reported as timed out" do
      started = Time.instant
      result = CommandRunner.run(["/bin/sh", "-c", "echo $$; exec /bin/sleep 30"], timeout: 200.milliseconds)
      elapsed = started.elapsed

      assert(elapsed >= 200.milliseconds)
      assert(elapsed < 1.second)
      assert(result.timed_out_after! == 200.milliseconds)
      assert(result.exit_status == -1)
      assert(!result.success?)
      assert(result.failure("/bin/sleep") == "sleep timed out after 0.2 s")
      assert(!Process.exists?(sleeper_pid(result)))
    end

    test "a program that ignores TERM is killed a second later and reaped" do
      started = Time.instant
      result = CommandRunner.run(["/bin/sh", "-c", "trap '' TERM; echo $$; exec /bin/sleep 30"], timeout: 200.milliseconds)
      elapsed = started.elapsed

      assert(elapsed >= 1.2.seconds)
      assert(elapsed < 3.seconds)
      assert(result.timed_out?)
      assert(result.exit_status == -1)
      assert(!Process.exists?(sleeper_pid(result)))
    end

    test "a program that leaves its output open in a child it started is stopped at the time limit" do
      started = Time.instant
      result = CommandRunner.run(["/bin/sh", "-c", "/bin/sleep 5 & echo done"], timeout: 200.milliseconds)

      assert(started.elapsed < 3.seconds)
      assert(result.timed_out?)
      assert(result.output == "done\n")
    end

    test "a program that finishes within the time limit is not timed out" do
      result = CommandRunner.run(["/bin/sh", "-c", "/bin/sleep 0.1; echo done"], timeout: 5.seconds)

      assert(result.success?)
      assert(!result.timed_out?)
      assert(result.output == "done\n")
    end

    # The children of the test inherit its ignored `PIPE` signal, so `yes` ends
    # with an error message on standard error when `head` has had enough.
    test "standard output past 4096 bytes is drained and cut with a marker" do
      result = CommandRunner.run(["/bin/sh", "-c", "/usr/bin/yes 2>/dev/null | /usr/bin/head -c 100000"])

      assert(result.success?)
      assert(result.output == "y\n" * 2_048 + " … (truncated)")
      assert(result.error == "")
    end

    test "standard error past 4096 bytes is drained and cut with a marker" do
      result = CommandRunner.run(["/bin/sh", "-c", "/usr/bin/yes 2>/dev/null | /usr/bin/head -c 100000 >&2; echo out"])

      assert(result.success?)
      assert(result.output == "out\n")
      assert(result.error == "y\n" * 2_048 + " … (truncated)")
    end

    test "the output limit can be lowered" do
      result = CommandRunner.run(["/bin/sh", "-c", "echo 0123456789"], output_limit: 4)

      assert(result.output == "0123 … (truncated)")
    end

    test "at most four programs run at once and a fifth waits for one of them" do
      started = Time.instant
      finished = Channel(Time::Span).new(5)
      5.times do
        spawn do
          CommandRunner.run(["/bin/sleep", "1"])
          finished.send(started.elapsed)
        end
      end
      times = Array.new(5) { finished.receive }.sort!

      assert(times[3] < 2.seconds)
      assert(times[4] >= 2.seconds)
    end

    test "a program that cannot be started gives its slot back" do
      5.times do
        raised(IO::Error) { CommandRunner.run(["/nonexistent/tunnelgeist-test"]) }
      end
      done = Channel(CommandRunner::Result).new(1)
      spawn { done.send(CommandRunner.run(["/usr/bin/true"])) }

      select
      when result = done.receive
        assert(result.success?)
      when timeout(5.seconds)
        raise "no slot was free after five failed starts"
      end
    end

    test "input past what the program reads does not stop the run" do
      result = CommandRunner.run(["/usr/bin/head", "-c", "3"], input: "x" * 1_000_000)

      assert(result.success?)
      assert(result.output == "xxx")
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
