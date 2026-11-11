{% skip_file unless flag?(:darwin) %}

require "./address_request"
require "./operation"

module Tunnelgeist
  module Protocol
    # Asks the daemon to add the address to the device; the reply is ok or an
    # error.
    struct AddAddress < AddressRequest
      # The operation of every request of this type.
      def self.operation : Operation
        Operation::AddAddress
      end
    end
  end
end
