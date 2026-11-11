{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  struct Prefix
    # Raised by `.parse` and `.parse_address`; the message is
    # `invalid prefix "TEXT": REASON`.
    class ParseError < ArgumentError
      # The part of the message after the colon, such as `invalid address`.
      getter reason : String

      # An error for the invalid *text*, with the *reason* it is invalid.
      def initialize(text : String, *, @reason : String)
        super("invalid prefix #{text.inspect}: #{reason}")
      end
    end
  end
end
