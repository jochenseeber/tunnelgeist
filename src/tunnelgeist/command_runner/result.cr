{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  module CommandRunner
    # What a program run by `CommandRunner` produced: its exit status
    # (-1 when a signal killed it), standard output and standard error.
    record Result, exit_status : Int32, output : String, error : String do
      # Whether the program exited with status 0.
      def success? : Bool
        exit_status == 0
      end
    end
  end
end
