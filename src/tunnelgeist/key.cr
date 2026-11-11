{% skip_file unless flag?(:darwin) %}

require "crypto/subtle"
require "random/secure"

module Tunnelgeist
  # The bearer key of a device (UA6, UD4): 32 random bytes as unpadded
  # base64url, 43 characters of `A-Za-z0-9_-`. `inspect` never shows it, so
  # it stays out of `pp` output (UC5); `to_s` is the text a client passes on.
  struct Key
    # The number of characters of every key.
    private SIZE = 43

    @text : String

    # A new random key.
    def self.generate : Key
      new(checked: Random::Secure.urlsafe_base64(32, padding: false))
    end

    # The key *text*, or nil when it does not have the form of a key.
    def self.parse?(text : String) : Key?
      new(checked: text) if form?(text)
    end

    # Whether *text* has the form of a key: `SIZE` characters, each an ASCII
    # letter or digit, `_` or `-`.
    private def self.form?(text : String) : Bool
      text.size == SIZE && text.each_char.all? { |char| char.ascii_alphanumeric? || char == '_' || char == '-' }
    end

    # The key *text*; raises `ArgumentError` when `parse?` refuses it. The
    # message leaves the text out, since it may be a key.
    def self.new(text : String) : Key
      parse?(text) || raise ArgumentError.new("a key must be 43 characters of A-Za-z0-9_-")
    end

    private def initialize(*, checked @text : String)
    end

    # Whether *other* is the same key, compared in constant time.
    def matches?(other : Key) : Bool
      Crypto::Subtle.constant_time_compare(@text, other.to_s)
    end

    # The same as `matches?`, so a plain comparison is constant-time too.
    def ==(other : Key) : Bool
      matches?(other)
    end

    # Hashes the key text, so equal keys hash alike and a `Key` can be a
    # hash key.
    def hash(hasher : Crystal::Hasher) : Crystal::Hasher
      @text.hash(hasher)
    end

    # The key as it travels on the wire.
    def to_s(io : IO) : Nil
      io << @text
    end

    # Writes `#<Key [REDACTED]>`, never the key, so `pp` output and an
    # inspected container keep it out of the log (UC5).
    def inspect(io : IO) : Nil
      io << "#<Key [REDACTED]>"
    end
  end
end
