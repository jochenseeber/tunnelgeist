{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  abstract class CheckedDirectory
    # A directory or file a `CheckedDirectory` refused to open or read: the
    # path walked up to it and why. The message is `PATH: REASON`.
    class Refusal < Exception
      # The path of the directory or file refused, from `/`.
      getter path : String
      # Why it was refused, without the path.
      getter reason : String

      # A refusal of *path* for *reason*.
      def initialize(@reason : String, *, @path : String, cause : Exception? = nil)
        super("#{@path}: #{@reason}", cause)
      end
    end
  end
end
