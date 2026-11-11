{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  module Protocol
    # A request or reply the protocol rejects; the message is the text
    # of the error reply.
    class Error < Exception
      # The field the error is about, for every error about one field (a
      # missing, mistyped, unknown or invalid value); nil for the errors about
      # the request or reply as a whole.
      getter field : String?

      # An error with *message*, about the field *field* when given.
      def initialize(message : String? = nil, *, cause : Exception? = nil, @field : String? = nil)
        super(message, cause)
      end

      # The field the error is about; raises `NilAssertionError` when it is
      # about no single field.
      def field! : String
        @field || raise NilAssertionError.new("the error is not about a field: #{message}")
      end
    end
  end
end
