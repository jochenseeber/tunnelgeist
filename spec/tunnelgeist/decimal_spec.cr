require "../spec_helper"
require "../../src/tunnelgeist/decimal"

# The checks of decimal numbers in text, by ASCII digits alone.
describe Tunnelgeist::Decimal do
  {% if flag?(:darwin) %}
    alias Decimal = Tunnelgeist::Decimal

    # Text that is no decimal number for either check: empty, signed, spaced,
    # with a trailing newline, digits of other scripts (Arabic-Indic `٣`,
    # full-width `３`) and a byte that is not UTF-8.
    NOT_DECIMAL = ["", "+1", "-1", " 1", "1 ", "1\n", "\n1", "1_0", "0x1", "1.0", "٣", "1٣", "３", "1３",
                   String.new(Bytes[0x31, 0xff])]

    test "digits? takes one or more ASCII digits, leading zeros included" do
      ["0", "7", "00", "007", "4294967296", "1234567890"].each do |text|
        assert(Decimal.digits?(text))
      end
    end

    test "digits? refuses anything but ASCII digits" do
      NOT_DECIMAL.each do |text|
        assert(!Decimal.digits?(text))
      end
    end

    test "canonical? takes ASCII digits without a leading zero, and 0 itself" do
      ["0", "7", "10", "4294967296"].each do |text|
        assert(Decimal.canonical?(text))
      end
    end

    test "canonical? refuses a leading zero and anything but ASCII digits" do
      (["00", "01", "007"] + NOT_DECIMAL).each do |text|
        assert(!Decimal.canonical?(text))
      end
    end
  {% end %}
end
