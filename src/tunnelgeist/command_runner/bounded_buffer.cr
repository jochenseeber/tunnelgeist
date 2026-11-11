{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  module CommandRunner
    # Keeps the first *limit* bytes of a program's standard output or
    # standard error and drops the rest, so that a program that writes
    # without end neither blocks on a full pipe nor fills the daemon's
    # memory (RF2.2).
    class BoundedBuffer
      # Appended to the text of a buffer that dropped bytes.
      TRUNCATION_MARKER = " … (truncated)"

      # Whether bytes were dropped because the buffer was full.
      getter? truncated : Bool = false

      @kept : IO::Memory

      # A buffer that keeps at most *limit* bytes; raises `ArgumentError`
      # for a negative *limit*.
      def initialize(*, @limit : Int32)
        raise ArgumentError.new("limit must not be negative: #{limit}") if limit < 0

        @kept = IO::Memory.new
      end

      # Keeps as much of *bytes* as fits the limit and drops the rest.
      def append(bytes : Bytes) : Nil
        room = @limit - @kept.size
        if bytes.size > room
          @kept.write(bytes[0, room])
          @truncated = true
        else
          @kept.write(bytes)
        end
      end

      # The bytes kept, as text, followed by `TRUNCATION_MARKER` when bytes
      # were dropped.
      def text : String
        kept = @kept.to_s
        truncated? ? kept + TRUNCATION_MARKER : kept
      end
    end
  end
end
