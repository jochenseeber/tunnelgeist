{% skip_file unless flag?(:darwin) %}

require "../config"
require "../install"
require "./starter"

module Tunnelgeist
  class Install
    # Where `install` puts the daemon and what its property list names:
    # the *binary*, the *plist*, the main file of the configuration
    # *config* and the *log*. Every directory from `/` down to the ones
    # `install` writes in must pass `TrustPolicy` for root (UC3), which
    # `Writer` checks. The socket is not here: it comes from the
    # configuration (CA7).
    record Paths, binary : String, plist : String, config : String, log : String do
      # The paths of a real installation, with the configuration at
      # *config*, which `install --config` names. A relative *config* is
      # made absolute against the current directory: launchd starts the
      # daemon in `/`, so the property list must not carry a relative path.
      def self.default(*, config : String = Config::DEFAULT_PATH) : Paths
        new(binary: "/usr/local/libexec/tunnelgeist", plist: "/Library/LaunchDaemons/#{LABEL}.plist",
          config: File.expand_path(config), log: "/var/log/tunnelgeist.log")
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
    end
  end
end
