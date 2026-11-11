{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  module CommandRunner
    # What a program run by `CommandRunner` produced: its exit status
    # (-1 when a signal killed it), standard output and standard error, each
    # cut at the output limit, and the time limit it ran out of, nil when it
    # finished in time.
    record Result, exit_status : Int32, output : String, error : String, timed_out_after : Time::Span? = nil do
      # Whether the program exited with status 0 within its time limit.
      def success? : Bool
        !timed_out? && exit_status == 0
      end

      # Whether the program ran out of time and was stopped.
      def timed_out? : Bool
        !timed_out_after.nil?
      end

      # The time limit the program ran out of; raises `NilAssertionError`
      # when it finished in time.
      def timed_out_after! : Time::Span
        timed_out_after || raise NilAssertionError.new("the program finished in time, with exit status #{exit_status}")
      end

      # How the program ended, for an error text that names the program
      # before it: `exited 1: route: File exists` with the standard error
      # stripped, or `timed out after 10 s`.
      def outcome : String
        limit = timed_out_after
        limit ? "timed out after #{seconds(limit)} s" : "exited #{exit_status}: #{error.strip}"
      end

      # The error text of a failed run of *program*, an absolute path: the
      # path and the exit (`/sbin/route exited 1: route: File exists`), or
      # the program's name and the time limit (`ifconfig timed out after
      # 10 s`).
      def failure(program : String) : String
        name = timed_out? ? File.basename(program) : program
        "#{name} #{outcome}"
      end

      # *span* in seconds, without a fraction when it is whole.
      private def seconds(span : Time::Span) : String
        whole = span.total_seconds.to_i64
        whole.seconds == span ? whole.to_s : span.total_seconds.to_s
      end
    end
  end
end
