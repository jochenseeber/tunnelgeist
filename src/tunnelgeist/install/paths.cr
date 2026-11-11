{% skip_file unless flag?(:darwin) %}

require "../config"
require "../install"
require "./starter"

module Tunnelgeist
  class Install
    # Where `install` puts the daemon and what its property list names:
    # the *binary*, the *plist*, the main file of the configuration
    # *config* and the *log*. *root* is the directory below which the
    # binary goes; it and every directory between it and the binary must be
    # owned by root and writable only by root (UC3). The socket is not
    # here: it comes from the configuration (CA7).
    record Paths, binary : String, plist : String, config : String, log : String, root : String do
      # The paths of a real installation, with the configuration at
      # *config*, which `install --config` names. A relative *config* is
      # made absolute against the current directory: launchd starts the
      # daemon in `/`, so the property list must not carry a relative path.
      def self.default(*, config : String = Config::DEFAULT_PATH) : Paths
        new(binary: "/usr/local/libexec/tunnelgeist", plist: "/Library/LaunchDaemons/#{LABEL}.plist",
          config: File.expand_path(config), log: "/var/log/tunnelgeist.log", root: "/usr/local")
      end

      # The directory of the main configuration file, which `uninstall`
      # leaves in place.
      def config_directory : String
        File.dirname(config)
      end

      # The directory the starter configuration's include pattern reads
      # client configurations from.
      def clients_directory : String
        File.join(config_directory, Starter::CLIENTS_DIRECTORY)
      end

      # *root* and each directory below it down to the one that holds
      # *binary*, in that order. Raises `ArgumentError` when *binary* is not
      # below *root*.
      def binary_directories : Array(String)
        directories = [] of String
        directory = File.dirname(binary)
        until directory == root
          parent = File.dirname(directory)
          raise ArgumentError.new("#{binary} is not below #{root}") if parent == directory

          directories.unshift(directory)
          directory = parent
        end
        directories.unshift(root)
      end
    end
  end
end
