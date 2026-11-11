require "../../spec_helper"
require "../../../src/tunnelgeist/command_runner/result"

# What a program run by the command runner produced, and the texts that say
# how it failed (UP6, RF2.1).
describe Tunnelgeist::CommandRunner::Result do
  {% if flag?(:darwin) %}
    alias Result = Tunnelgeist::CommandRunner::Result

    test "success? is true only for exit status 0 within the time limit" do
      assert(Result.new(exit_status: 0, output: "", error: "").success?)
      assert(!Result.new(exit_status: 1, output: "", error: "").success?)
      assert(!Result.new(exit_status: 0, output: "", error: "", timed_out_after: 10.seconds).success?)
    end

    test "timed_out? says whether the program ran out of time" do
      assert(!Result.new(exit_status: 1, output: "", error: "").timed_out?)
      assert(Result.new(exit_status: -1, output: "", error: "", timed_out_after: 10.seconds).timed_out?)
    end

    test "timed_out_after! is the time limit the program ran out of" do
      result = Result.new(exit_status: -1, output: "", error: "", timed_out_after: 10.seconds)

      assert(result.timed_out_after! == 10.seconds)
    end

    test "timed_out_after! raises for a program that finished in time" do
      error = raised(NilAssertionError) { Result.new(exit_status: 3, output: "", error: "").timed_out_after! }

      assert(error.message == "the program finished in time, with exit status 3")
    end

    test "outcome of an exit is the exit status and the standard error without surrounding white space" do
      result = Result.new(exit_status: 1, output: "ignored", error: "  route: File exists\n")

      assert(result.outcome == "exited 1: route: File exists")
    end

    test "outcome of a timeout is the time limit in seconds" do
      assert(Result.new(exit_status: -1, output: "", error: "x", timed_out_after: 10.seconds).outcome ==
             "timed out after 10 s")
      assert(Result.new(exit_status: -1, output: "", error: "", timed_out_after: 250.milliseconds).outcome ==
             "timed out after 0.25 s")
    end

    test "failure of an exit names the program by its path" do
      result = Result.new(exit_status: 1, output: "", error: "route: File exists\n")

      assert(result.failure("/sbin/route") == "/sbin/route exited 1: route: File exists")
    end

    test "failure of a timeout names the program by its name" do
      result = Result.new(exit_status: -1, output: "", error: "", timed_out_after: 10.seconds)

      assert(result.failure("/sbin/ifconfig") == "ifconfig timed out after 10 s")
    end
  {% end %}
end
