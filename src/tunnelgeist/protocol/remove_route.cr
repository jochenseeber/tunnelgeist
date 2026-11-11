{% skip_file unless flag?(:darwin) %}

require "./operation"
require "./route_request"

module Tunnelgeist
  module Protocol
    # Asks the daemon to remove a route it added through the device; the reply
    # is ok or an error.
    struct RemoveRoute < RouteRequest
      # The operation of every request of this type.
      def self.operation : Operation
        Operation::RemoveRoute
      end
    end
  end
end
