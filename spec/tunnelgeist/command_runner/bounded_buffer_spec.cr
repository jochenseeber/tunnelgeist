require "../../spec_helper"
require "../../../src/tunnelgeist/command_runner/bounded_buffer"

# The buffer that keeps the first bytes of a program's output and drops the
# rest (RF2.2).
describe Tunnelgeist::CommandRunner::BoundedBuffer do
  {% if flag?(:darwin) %}
    alias BoundedBuffer = Tunnelgeist::CommandRunner::BoundedBuffer

    test "text is everything appended while it fits the limit" do
      buffer = BoundedBuffer.new(limit: 8)
      buffer.append("abc".to_slice)
      buffer.append("defgh".to_slice)

      assert(!buffer.truncated?)
      assert(buffer.text == "abcdefgh")
    end

    test "text is empty when nothing was appended" do
      buffer = BoundedBuffer.new(limit: 8)

      assert(!buffer.truncated?)
      assert(buffer.text == "")
    end

    test "text keeps the first bytes up to the limit and marks the cut" do
      buffer = BoundedBuffer.new(limit: 4)
      buffer.append("abc".to_slice)
      buffer.append("defgh".to_slice)
      buffer.append("ijk".to_slice)

      assert(buffer.truncated?)
      assert(buffer.text == "abcd … (truncated)")
    end

    test "the marker is a space, an ellipsis and the word truncated in parentheses" do
      assert(BoundedBuffer::TRUNCATION_MARKER == " … (truncated)")
    end

    test "an append after the limit is reached marks the cut" do
      buffer = BoundedBuffer.new(limit: 3)
      buffer.append("abc".to_slice)

      assert(!buffer.truncated?)

      buffer.append("d".to_slice)

      assert(buffer.truncated?)
      assert(buffer.text == "abc … (truncated)")
    end

    test "an empty append changes nothing" do
      buffer = BoundedBuffer.new(limit: 3)
      buffer.append("abc".to_slice)
      buffer.append(Bytes.empty)

      assert(!buffer.truncated?)
      assert(buffer.text == "abc")
    end

    test "a limit below zero is refused" do
      error = raised(ArgumentError) { BoundedBuffer.new(limit: -1) }

      assert(error.message == "limit must not be negative: -1")
    end
  {% end %}
end
