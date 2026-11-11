{% skip_file unless flag?(:darwin) %}

require "./address_request"
require "./operation"

module Tunnelgeist
  module Protocol
    # Asks the daemon to remove an address it added to the device; the reply is
    # ok or an error.
    struct RemoveAddress < AddressRequest
      # The operation of every request of this type.
      def self.operation : Operation
        Operation::RemoveAddress
      end
    end
  end
end
