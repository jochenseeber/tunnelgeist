{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  # Checks of decimal numbers written in text. Only the ASCII digits `0-9`
  # count: `Char#number?` would also take the digits of other scripts, such
  # as `٣` or the full-width `３`, which `String#to_i` then refuses.
  module Decimal
    # Whether *text* is one or more ASCII digits and nothing else, leading
    # zeros included. An empty text, a sign, whitespace and a trailing
    # newline are refused.
    def self.digits?(text : String) : Bool
      !text.empty? && text.each_char.all?(&.ascii_number?)
    end

    # Whether *text* is a number as written without leading zeros: ASCII
    # digits, the first of them not `0` unless it is the only one.
    def self.canonical?(text : String) : Bool
      digits?(text) && (text.size == 1 || !text.starts_with?('0'))
    end
  end
end
