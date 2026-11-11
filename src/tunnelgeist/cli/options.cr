{% skip_file unless flag?(:darwin) %}

require "../config"
require "../install"
require "./command"
require "./flag"

module Tunnelgeist
  module CLI
    # The settings of one command, as `parse` read them from its arguments.
    class Options
      # The width of the column of flags in the help text, as
      # `OptionParser` laid it out; a description starts one space after
      # it.
      private FLAG_WIDTH = 32
      # The indent of each flag in the help text.
      private FLAG_INDENT = "    "

      # The group `install` creates when it is missing and writes into a
      # new starter configuration; `--group`, `Install::DEFAULT_GROUP` when
      # not given. An existing configuration keeps its own group, and
      # `serve` takes its group from the configuration.
      getter group : String
      # The main file of the configuration: `--config`,
      # `Config::DEFAULT_PATH` when not given.
      getter config : String
      # Whether the command line asked for the help text (`--help` or `-h`).
      getter? help : Bool
      # The help text of the command whose arguments were read.
      getter usage : String

      # The settings of a command with the help text *usage*; `parse` builds
      # them from the command line.
      def initialize(*, @usage : String, @group : String = Install::DEFAULT_GROUP,
                     @config : String = Config::DEFAULT_PATH, @help : Bool = false)
      end

      # Parses *args* with the flags *command* takes. A flag that takes a
      # value reads it from the next argument, whatever it is, or after `=`
      # (`--config=PATH`); `--` ends the flags. Raises `ArgumentError` for an
      # option the command does not take, a flag without its value and,
      # unless the help was asked for, an argument that is no option.
      def self.parse(*, command : Command, args : Array(String)) : Options
        flags = flags_of(command)
        group = Install::DEFAULT_GROUP
        config = Config::DEFAULT_PATH
        help = false
        extra = [] of String
        pending = args.dup
        until pending.empty?
          argument = pending.shift
          if argument == "--"
            extra.concat(pending)
            break
          end
          unless option?(argument)
            extra << argument
            next
          end

          flag = find_flag(argument, flags: flags)
          case flag
          in .group?
            group = group_name(flag_value(argument, pending: pending))
          in .config?
            config = flag_value(argument, pending: pending)
          in .help?
            help = true
          end
        end
        raise ArgumentError.new("Unexpected argument #{extra.first.inspect}") unless help || extra.empty?

        new(usage: usage(command, flags: flags), group: group, config: config, help: help)
      end

      # The flags *command* takes, in the order its help text lists them.
      private def self.flags_of(command : Command) : Array(Flag)
        case command
        in .serve?
          [Flag::Config, Flag::Help]
        in .install?
          [Flag::Group, Flag::Config, Flag::Help]
        in .uninstall?, .version?, .help?
          [Flag::Help]
        end
      end

      # Whether *argument* is an option: it starts with `-` and is not `-`
      # alone, which is an ordinary argument.
      private def self.option?(argument : String) : Bool
        argument.starts_with?('-') && argument != "-"
      end

      # The flag of *flags* the option *argument* gives. Raises
      # `ArgumentError` for an option none of *flags* has and for a value
      # given to a flag that takes none, such as `--help=yes`.
      private def self.find_flag(argument : String, *, flags : Array(Flag)) : Flag
        flag = flags.find(&.names.includes?(flag_name(argument)))
        if flag.nil? || (inline_value?(argument) && !flag.value?)
          raise ArgumentError.new("Invalid option: #{argument}")
        end
        flag
      end

      # The value of the flag the option *argument* gives: the text after
      # its `=`, else the next argument, taken from the front of *pending*
      # whatever it is. Raises `ArgumentError` when there is none.
      private def self.flag_value(argument : String, *, pending : Array(String)) : String
        name = flag_name(argument)
        return argument[(name.size + 1)..] if inline_value?(argument)

        pending.shift? || raise ArgumentError.new("Missing option: #{name}")
      end

      # The name of the flag in the option *argument*: a long option up to
      # its `=`, any other the whole argument.
      private def self.flag_name(argument : String) : String
        inline_value?(argument) ? argument.partition('=')[0] : argument
      end

      # Whether the option *argument* carries its value after `=`, which
      # only a long option can: `-h=x` is no option at all.
      private def self.inline_value?(argument : String) : Bool
        argument.starts_with?("--") && argument.includes?('=')
      end

      # The help text of *command* with *flags*: the usage line, then each
      # flag with its description.
      private def self.usage(command : Command, *, flags : Array(Flag)) : String
        String.build do |io|
          io << "Usage: tunnelgeist " << command.word
          flags.select(&.value?).each { |flag| io << " [" << flag.synopsis << ']' }
          flags.each do |flag|
            # A flag without a short name is indented to line up with the
            # long name after a short one.
            synopsis = flag.synopsis.starts_with?("--") ? "    #{flag.synopsis}" : flag.synopsis
            padding = " " * Math.max(FLAG_WIDTH - synopsis.size, 0)
            io << '\n' << FLAG_INDENT << synopsis << padding << ' ' << flag.description
          end
        end
      end

      # *text* as a group name; one starting with `-` would read as an
      # option of `dseditgroup`.
      protected def self.group_name(text : String) : String
        if text.empty? || text.starts_with?('-')
          raise ArgumentError.new("--group must be a group name, got #{text.inspect}")
        end
        text
      end
    end
  end
end
