{% skip_file unless flag?(:darwin) %}

require "log"
require "../authorizer"
require "../config"
require "./error"

module Tunnelgeist
  struct Config
    # The configuration the daemon runs with and the `Authorizer` built from
    # it (CA4). The handler asks for `authorizer` once per connection, when
    # it admits the peer, and a reload swaps both together, so the one
    # request of a connection is judged by one configuration from start to
    # end, even when a reload comes before it arrives, and the next
    # connection by the new one.
    class Holder
      @mutex = Mutex.new
      @current : Config
      @authorizer : Authorizer
      # The path of the socket the daemon listens on for its whole life (CN4).
      @listening : String

      # Holds *config*, the configuration the daemon starts with, for a daemon
      # that listens on the socket at *listening*.
      def initialize(config : Config, *, listening : String)
        @current = config
        @authorizer = Authorizer.new(config)
        @listening = listening
      end

      # The configuration in use.
      def current : Config
        @mutex.synchronize { @current }
      end

      # The authorizer of the configuration in use.
      def authorizer : Authorizer
        @mutex.synchronize { @authorizer }
      end

      # Puts *config* and a new authorizer for it in place in one step, as it
      # is.
      def replace(config : Config) : Nil
        authorizer = Authorizer.new(config)
        @mutex.synchronize do
          @current = config
          @authorizer = authorizer
        end
      end

      # Loads the configuration again with *load* and replaces the one in use
      # with its clients (CA5). When *load* raises, logs why and keeps the
      # configuration in use, so a mistake in the file or a failed lookup does
      # not take the daemon down (CD4).
      #
      # Two fields take a new `install`, so a change to them is logged and
      # not applied (CN4). The socket is bound once, and launchd keeps the
      # path its property list names, so a `socket` other than the one the
      # daemon listens on asks for a reinstall. The main group also owns the
      # socket and is named in the refusal the handler sends, so the group
      # and its membership stay those in use, which keeps the socket, the
      # refusal and the check in agreement; launchd keeps the socket's gid
      # too, and a restart alone would check the new group against a socket
      # of the old one.
      def reload(*, load : -> Config, log : Log) : Nil
        loaded = load.call
      rescue error : Error
        log.error { "configuration reload failed: #{error.message}" }
      rescue error : Exception
        # Crystal ends the process when an exception escapes a signal
        # handler, so anything else the load raises, such as a failed
        # directory-service lookup, is logged and the reload abandoned too.
        log.error(exception: error) { "configuration reload failed: #{error.class}: #{error.message}" }
      else
        running = current
        replace(loaded.copy_with(group: running.group, membership: running.membership))
        log.info { "configuration reloaded clients=#{loaded.clients.size}" }
        unless loaded.socket == @listening
          log.warn { "configuration socket changed to #{loaded.socket}, reinstall to apply" }
        end
        unless loaded.group == running.group
          log.warn { "configuration group changed to #{loaded.group}, reinstall to apply" }
        end
      end
    end
  end
end
