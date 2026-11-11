{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  class Install
    # A step of `install` or `uninstall` that failed; the message is
    # printed as is. *program* and *exit_status* are set when a program
    # failed.
    class Failure < Exception
      # The program that failed, nil for a step that ran none.
      getter program : String?
      # The exit status of the program that failed, nil for a step that ran
      # none.
      getter exit_status : Int32?

      # A failure with *message*; *program* and *exit_status* say which program
      # failed and how.
      def initialize(message : String? = nil, *, cause : Exception? = nil, @program : String? = nil,
                     @exit_status : Int32? = nil)
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
    end
  end
end
