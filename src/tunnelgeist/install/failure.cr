{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  class Install
    # A step of `install` or `uninstall` that failed; the message is
    # printed as is. *program* and *exit_status* are set when a program
    # failed, and *timed_out_after* when it ran out of time.
    class Failure < Exception
      # The program that failed, nil for a step that ran none.
      getter program : String?
      # The exit status of the program that failed, nil for a step that ran
      # none.
      getter exit_status : Int32?
      # The time limit the program that failed ran out of, nil when it ended
      # by itself or no program failed.
      getter timed_out_after : Time::Span?

      # A failure with *message*; *program*, *exit_status* and
      # *timed_out_after* say which program failed and how.
      def initialize(message : String? = nil, *, cause : Exception? = nil, @program : String? = nil,
                     @exit_status : Int32? = nil, @timed_out_after : Time::Span? = nil)
        super(message, cause)
      end

      # The program that failed; raises `NilAssertionError` when no program
      # failed.
      def program! : String
        @program || raise NilAssertionError.new("no program failed: #{message}")
      end

      # The exit status of the program that failed; raises
      # `NilAssertionError` when no program failed.
      def exit_status! : Int32
        @exit_status || raise NilAssertionError.new("no program failed: #{message}")
      end

      # The time limit the program that failed ran out of; raises
      # `NilAssertionError` when none did.
      def timed_out_after! : Time::Span
        @timed_out_after || raise NilAssertionError.new("no program ran out of time: #{message}")
      end
    end
  end
end
