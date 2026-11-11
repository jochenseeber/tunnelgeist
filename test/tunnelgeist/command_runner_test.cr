require "../test_helper"
require "../../src/tunnelgeist/command_runner"

# The runner of UC4 hands a child no descriptor but standard input, output and
# error, and bounds its time, its output and how many run at once (RF2); it
# runs the system's programs (`/bin/sh`, `/bin/test`, `/bin/cat`,
# `/bin/sleep`, `/usr/bin/yes`, `/usr/bin/head`).
{% if flag?(:darwin) %}
  # `setrlimit`, which the standard library does not bind, to run out of
  # descriptors on purpose.
  lib TunnelgeistTestResourceLimit
    fun setrlimit(resource : LibC::Int, limit : LibC::Rlimit*) : LibC::Int
  end
{% end %}

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

    # The process id on the first line the shell printed. A shell that had
    # not printed it when its time limit ran out fails the test with what it
    # had printed.
    def printed_pid(result : CommandRunner::Result) : Int64
      pid = result.output.lines.first?.try(&.to_i64?)
      pid || raise "the shell printed no process id before its time limit; it printed #{result.output.inspect}"
    end

    test "a program that runs past the time limit is stopped with TERM, reaped and reported as timed out" do
      started = Time.instant
      result = CommandRunner.run(["/bin/sh", "-c", "echo $$; exec /bin/sleep 30"], timeout: 500.milliseconds)
      elapsed = started.elapsed

      assert(elapsed >= 500.milliseconds)
      assert(elapsed < 1.5.seconds)
      assert(result.timed_out_after! == 500.milliseconds)
      assert(result.exit_status == -1)
      assert(!result.success?)
      assert(result.failure("/bin/sleep") == "sleep timed out after 0.5 s")
      assert(!Process.exists?(printed_pid(result)))
    end

    test "a program that ignores TERM is killed a second later and reaped" do
      started = Time.instant
      result = CommandRunner.run(["/bin/sh", "-c", "trap '' TERM; echo $$; exec /bin/sleep 30"], timeout: 500.milliseconds)
      elapsed = started.elapsed

      assert(elapsed >= 1.5.seconds)
      assert(elapsed < 3.5.seconds)
      assert(result.timed_out?)
      assert(result.exit_status == -1)
      assert(!Process.exists?(printed_pid(result)))
    end

    # Whether process *pid* is gone within a second: a child of a stopped
    # program is reaped by launchd, not by the test, so it may linger briefly.
    def gone?(pid : Int64) : Bool
      deadline = Time.instant + 1.second
      while Process.exists?(pid)
        return false if Time.instant >= deadline

        sleep 10.milliseconds
      end
      true
    end

    test "a program that ended but left its output open in a child it started times out with its exit status and the child is stopped" do
      started = Time.instant
      result = CommandRunner.run(["/bin/sh", "-c", "/bin/sleep 30 & echo $!; echo done"], timeout: 500.milliseconds)
      sleeper = printed_pid(result)
      begin
        assert(started.elapsed < 3.seconds)
        assert(result.timed_out?)
        assert(result.exit_status == 0)
        assert(result.output.lines.last? == "done")
        assert(gone?(sleeper))
      ensure
        Process.signal(Signal::KILL, sleeper) if Process.exists?(sleeper)
      end
    end

    test "a child the program started is stopped with the program when the time runs out" do
      result = CommandRunner.run(["/bin/sh", "-c", "/bin/sleep 30 & echo $!; wait"], timeout: 500.milliseconds)
      sleeper = printed_pid(result)
      begin
        assert(result.timed_out?)
        assert(gone?(sleeper))
      ensure
        Process.signal(Signal::KILL, sleeper) if Process.exists?(sleeper)
      end
    end

    test "the program runs in a process group of its own" do
      result = CommandRunner.run(["/bin/sh", "-c", "echo $$; /bin/ps -o pgid= -p $$"])

      lines = result.output.lines.map(&.strip)
      assert(result.success?)
      assert(lines.size == 2)
      assert(lines[0] == lines[1])
      assert(lines[1] != Process.pgid.to_s)
    end

    # The test ignores `PIPE`, as every Crystal program does; a child that
    # inherited that would make `yes` report a write error once `head` ends.
    test "the program gets the default action of a signal the runner ignores" do
      result = CommandRunner.run(["/bin/sh", "-c", "/usr/bin/yes | /usr/bin/head -c 1"])

      assert(result.success?)
      assert(result.output == "y")
      assert(result.error == "")
    end

    test "a program that finishes within the time limit is not timed out" do
      result = CommandRunner.run(["/bin/sh", "-c", "/bin/sleep 0.1; echo done"], timeout: 5.seconds)

      assert(result.success?)
      assert(!result.timed_out?)
      assert(result.output == "done\n")
    end

    test "standard output past 4096 bytes is drained and cut with a marker" do
      result = CommandRunner.run(["/bin/sh", "-c", "/usr/bin/yes | /usr/bin/head -c 100000"])

      assert(result.success?)
      assert(result.output == "y\n" * 2_048 + " … (truncated)")
      assert(result.error == "")
    end

    test "standard error past 4096 bytes is drained and cut with a marker" do
      result = CommandRunner.run(["/bin/sh", "-c", "/usr/bin/yes | /usr/bin/head -c 100000 >&2; echo out"])

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

    # The descriptors below 1024 open in this process.
    def open_descriptors : Array(Int32)
      (0...1_024).select { |fd| LibC.fcntl(fd, LibC::F_GETFD) != -1 }
    end

    # Runs the block with the soft descriptor limit at *limit*.
    def with_descriptor_limit(limit : UInt64, &) : Nil
      raise IO::Error.from_errno("getrlimit") unless LibC.getrlimit(LibC::RLIMIT_NOFILE, out original) == 0

      lowered = LibC::Rlimit.new(rlim_cur: limit, rlim_max: original.rlim_max)
      raise IO::Error.from_errno("setrlimit") unless TunnelgeistTestResourceLimit.setrlimit(LibC::RLIMIT_NOFILE, pointerof(lowered)) == 0

      begin
        yield
      ensure
        TunnelgeistTestResourceLimit.setrlimit(LibC::RLIMIT_NOFILE, pointerof(original))
      end
    end

    test "a run that runs out of descriptors for its pipes closes the ones it made" do
      CommandRunner.run(["/usr/bin/true"])
      before = open_descriptors
      free = (0...1_024).reject { |fd| before.includes?(fd) }
      # Room for the first pipe and one end of the second.
      limit = (free[2] + 1).to_u64

      with_descriptor_limit(limit) do
        raised(IO::Error) { CommandRunner.run(["/usr/bin/true"]) }
      end

      assert(open_descriptors == before)
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
