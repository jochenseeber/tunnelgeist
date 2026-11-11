require "../spec_helper"
require "../../src/tunnelgeist/key"

# The bearer key of a device (UA6, UD4).
describe Tunnelgeist::Key do
  {% if flag?(:darwin) %}
    alias Key = Tunnelgeist::Key

    KEY_TEXT = "Kq3vZ8xY1wT5uR7oP2nM4lK6jH9gF0dS_aB-cDeFgHi"

    test "generate gives 43 url-safe characters, different every time" do
      keys = Array.new(20) { Key.generate }

      assert(keys.all?(&.to_s.matches?(/\A[A-Za-z0-9_-]{43}\z/)))
      assert(keys.map(&.to_s).uniq.size == 20)
    end

    test "parse? takes 43 characters of A-Za-z0-9_- and nothing else" do
      assert(Key.parse?(KEY_TEXT).try(&.to_s) == KEY_TEXT)
      ["", KEY_TEXT[0, 42], "#{KEY_TEXT}x", KEY_TEXT.sub('K', '+'), KEY_TEXT.sub('K', '='), " #{KEY_TEXT[1..]}"].each do |text|
        assert(Key.parse?(text).nil?)
      end
    end

    test "parse? refuses non-ASCII letters and digits, a trailing newline and a byte that is not UTF-8" do
      [KEY_TEXT.sub('K', 'Ｋ'), KEY_TEXT.sub('K', 'é'), KEY_TEXT.sub('1', '٣'), "#{KEY_TEXT[0, 42]}\n", "#{KEY_TEXT}\n",
       String.new(KEY_TEXT.to_slice.dup.tap { |bytes| bytes[0] = 0xff_u8 })].each do |text|
        assert(Key.parse?(text).nil?)
      end
    end

    test "new raises ArgumentError for a malformed key without quoting it" do
      text = KEY_TEXT.sub('K', '!')
      error = raised(ArgumentError) { Key.new(text) }

      assert(!error.message.to_s.includes?(text))
      assert(Key.new(KEY_TEXT).to_s == KEY_TEXT)
    end

    test "matches? and == compare equal keys and refuse every other key" do
      key = Key.generate

      assert(key.matches?(Key.new(key.to_s)))
      assert(key == Key.new(key.to_s))
      assert(key.hash == Key.new(key.to_s).hash)
      assert(!key.matches?(Key.generate))
      assert(key != Key.generate)
    end

    test "inspect does not show the key" do
      key = Key.new(KEY_TEXT)

      [key.inspect, [key].inspect, {key: key}.inspect].each do |text|
        assert(!text.includes?(KEY_TEXT))
        assert(text.includes?("#<Key [REDACTED]>"))
      end
    end
  {% end %}
end
