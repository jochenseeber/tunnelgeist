{% skip_file unless flag?(:darwin) %}

require "./command_runner/result"
require "./inherited_descriptors"

module Tunnelgeist
  # Runs the argument vectors of `Commands` for the handler
  # (UC4): by absolute path, without a shell, with an empty environment.
  module CommandRunner
    # Runs an argument vector and returns its `Result`.
    alias Run = Array(String) -> Result

    # The runner of the daemon. Standard input is the null device; a
    # program killed by a signal reports exit status -1.
    def self.default : Run
      ->(argv : Array(String)) { run(argv) }
    end

    # Runs *argv*, with *input* as its standard input when given; raises
    # `IO::Error` when the program cannot be started. Every descriptor above 2
    # is closed in the child, whoever opened it.
    def self.run(argv : Array(String), *, input : String? = nil) : Result
      output = IO::Memory.new
      error = IO::Memory.new
      InheritedDescriptors.mark_close_on_exec
      stdin = input ? IO::Memory.new(input) : Process::Redirect::Close
      status = Process.run(argv[0], argv[1..], env: {} of String => String, clear_env: true, input: stdin,
        output: output, error: error)
      Result.new(exit_status: status.exit_code? || -1, output: output.to_s, error: error.to_s)
    end
  end
end
