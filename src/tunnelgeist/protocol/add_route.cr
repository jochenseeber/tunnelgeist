{% skip_file unless flag?(:darwin) %}

require "./operation"
require "./route_request"

module Tunnelgeist
  module Protocol
    # Asks the daemon to route the prefix through the device; the reply is ok or
    # an error.
    struct AddRoute < RouteRequest
      # The operation of every request of this type.
      def self.operation : Operation
        Operation::AddRoute
      end
    end
  end
end
