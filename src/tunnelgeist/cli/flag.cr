{% skip_file unless flag?(:darwin) %}

require "../config"
require "../install"

module Tunnelgeist
  module CLI
    # An option a command of `tunnelgeist` takes.
    enum Flag
      # `--group GROUP` of `install`.
      Group
      # `--config PATH` of `serve` and `install`.
      Config
      # `-h` or `--help`, which every command takes.
      Help

      # The names that give the flag on the command line.
      def names : Array(String)
        case self
        in .group?
          ["--group"]
        in .config?
          ["--config"]
        in .help?
          ["-h", "--help"]
        end
      end

      # Whether the flag takes a value, as the next argument or after `=`.
      def value? : Bool
        !help?
      end

      # The flag as the usage line and the help text show it, such as
      # `--config PATH`.
      def synopsis : String
        case self
        in .group?
          "--group GROUP"
        in .config?
          "--config PATH"
        in .help?
          "-h, --help"
        end
      end

      # The help text of the flag.
      def description : String
        case self
        in .group?
          "The group of a new starter configuration, created if missing (default #{Install::DEFAULT_GROUP})"
        in .config?
          "The configuration file (default #{Tunnelgeist::Config::DEFAULT_PATH})"
        in .help?
          "Show this help"
        end
      end
    end
  end
end
