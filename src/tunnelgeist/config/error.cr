{% skip_file unless flag?(:darwin) %}

require "./location"

module Tunnelgeist
  struct Config
    # A configuration the daemon refuses to load: the file it is about, the
    # field when the error is about one, where in the file when the JSON
    # reader found it, and why. The message is `FILE: REASON` or
    # `FILE: field FIELD: REASON`, with `:LINE:COLUMN` after `FILE` when
    # there is a location.
    class Error < Exception
      # The file or directory the error is about.
      getter file : String
      # The path of the field the error is about, such as `name` in an
      # included file or `clients[0].addresses[1].peer` in the main file; nil
      # for an error about the file as a whole.
      getter field : String?
      # Where in the file the JSON reader found the error; nil for an error
      # the loader's own checks found, which names the field instead.
      getter location : Location?
      # Why the configuration is refused, without the file, location and
      # field.
      getter reason : String

      # An error about *file*, and its *field* and *location* when given, for
      # *reason*.
      def initialize(@reason : String, *, @file : String, @field : String? = nil, @location : Location? = nil,
                     cause : Exception? = nil)
        super(build_message, cause)
      end

      # The field the error is about; raises `NilAssertionError` when it is
      # about the file as a whole.
      def field! : String
        @field || raise NilAssertionError.new("the error is not about a field: #{message}")
      end

      # Where in the file the error is; raises `NilAssertionError` when it
      # has no location.
      def location! : Location
        @location || raise NilAssertionError.new("the error has no location: #{message}")
      end

      private def build_message : String
        String.build do |io|
          io << @file
          @location.try { |location| io << ':' << location }
          io << ": "
          @field.try { |field| io << "field " << field << ": " }
          io << @reason
        end
      end
    end
  end
end
