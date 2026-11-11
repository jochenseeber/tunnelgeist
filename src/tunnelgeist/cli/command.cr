{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  module CLI
    # A command of `tunnelgeist`, named by the first command line argument.
    enum Command
      Serve
      Install
      Uninstall
      Version
      Help

      # The command *argument* names, nil for any other text. `-h` and
      # `--help` name `Help`, `--version` names `Version`. The match is
      # exact: `Enum.parse?` would also accept `"Serve"` and `"un_install"`.
      def self.from_argument?(argument : String) : Command?
        return Help if argument == "-h" || argument == "--help"
        return Version if argument == "--version"

        each do |command|
          return command if command.word == argument
        end
        nil
      end

      # The word that names the command on the command line.
      def word : String
        case self
        in .serve?
          "serve"
        in .install?
          "install"
        in .uninstall?
          "uninstall"
        in .version?
          "version"
        in .help?
          "help"
        end
      end
    end
  end
end
