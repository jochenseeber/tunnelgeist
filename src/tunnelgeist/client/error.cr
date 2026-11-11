{% skip_file unless flag?(:darwin) %}

require "./error/reason"

class Tunnelgeist::Client
  # A failure to reach the daemon or an error reply of it.
  class Error < IO::Error
    # Why the call failed.
    getter reason : Reason

    # An error with the failure class *reason*; *cause* is the underlying
    # exception, if any.
    def initialize(message : String? = nil, *, reason : Reason, cause : Exception? = nil)
      @reason = reason
      super(message, cause)
    end
  end
end
