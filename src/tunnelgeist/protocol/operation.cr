{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  module Protocol
    # The operation of a request, `op` on the wire.
    enum Operation
      Create
      AddAddress
      RemoveAddress
      AddRoute
      RemoveRoute

      # The name of the operation in the JSON of a request and in the log.
      def wire : String
        case self
        in .create?
          "create"
        in .add_address?
          "add_address"
        in .remove_address?
          "remove_address"
        in .add_route?
          "add_route"
        in .remove_route?
          "remove_route"
        end
      end

      # The operation whose `wire` name is exactly *text*, nil for any other
      # text. `Enum.parse?` would also accept `"Create"` and `"addaddress"`,
      # which the protocol rejects.
      def self.from_wire?(text : String) : Operation?
        each do |operation|
          return operation if operation.wire == text
        end
        nil
      end
    end
  end
end
