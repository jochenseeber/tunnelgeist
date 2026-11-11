{% skip_file unless flag?(:darwin) %}

require "./command_runner/execution"
require "./command_runner/result"

module Tunnelgeist
  # Runs the argument vectors of `Commands` for the handler and the programs
  # of `Install` (UC4): by absolute path, without a shell, with an empty
  # environment, and bounded in time, output and number (RF2).
  module CommandRunner
    # How long a program may run before it is stopped (RF2.1).
    COMMAND_TIMEOUT = 10.seconds

    # How many bytes of each of a program's standard output and standard
    # error are kept (RF2.2).
    COMMAND_OUTPUT_LIMIT = 4_096

    # How many programs run at once in the whole daemon; a further run waits
    # for one of them to end (RF2.3).
    COMMAND_CONCURRENCY = 4

    # One token per program running: a run sends one before it starts its
    # program, which blocks while all are taken, and receives it back when
    # the program has ended.
    private SLOTS = Channel(Nil).new(COMMAND_CONCURRENCY)

    # Runs an argument vector and returns its `Result`.
    alias Run = Array(String) -> Result

    # The runner of the daemon, with the limits above. Standard input is
    # the null device; a program killed by a signal, also when it is stopped
    # for running out of time, reports exit status -1.
    def self.default : Run
      ->(argv : Array(String)) { run(argv) }
    end

    # Runs *argv*, with *input* as its standard input when given, and
    # returns its `Result` once it has ended; raises `IO::Error` when the
    # program cannot be started. The program leads a process group of its
    # own, starts with every signal at its default action, and inherits no
    # descriptor above 2, whoever opened it.
    #
    # The run waits while `COMMAND_CONCURRENCY` other programs run. A
    # program still running after *timeout* is sent `TERM`, and `KILL` a
    # second later, and is reaped; its result is timed out. A program that
    # ended but left its output open in a process it started is timed out
    # too, with the exit status it ended with. The signals go to the
    # program's process group, so they also reach the processes it started
    # that stayed in it. Of each of standard
    # output and standard error the first *output_limit* bytes are kept and
    # the rest is read and dropped.
    def self.run(argv : Array(String), *, input : String? = nil, timeout : Time::Span = COMMAND_TIMEOUT,
                 output_limit : Int32 = COMMAND_OUTPUT_LIMIT) : Result
      SLOTS.send(nil)
      begin
        execution = Execution.start(argv, input: input, output_limit: output_limit)
        execution.finish(timeout)
      ensure
        SLOTS.receive
      end
    end
  end
end
