{% skip_file unless flag?(:darwin) %}

require "./config/client"
require "./config/loader"
require "./membership"

module Tunnelgeist
  # The daemon's configuration (CF1): the socket path, the main group every
  # client must belong to, resolved to its `Membership`, and the client
  # configurations of the main file followed by those of its includes.
  record Config, socket : String, group : String, membership : Membership, clients : Array(Config::Client) do
    # The main file of the configuration the daemon uses unless `--config`
    # names another one.
    DEFAULT_PATH = "/usr/local/etc/tunnelgeist/config.json"

    # Loads the configuration whose main file is *path*, as the daemon's
    # effective uid with the system's users, groups and Security; raises
    # `Config::Error` naming the file and field. See `Loader`.
    def self.load(path : String) : Config
      Loader.new(path: path).load
    end
  end
end
