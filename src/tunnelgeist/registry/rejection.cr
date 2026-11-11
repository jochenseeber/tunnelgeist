{% skip_file unless flag?(:darwin) %}

require "../protocol/common"

module Tunnelgeist
  class Registry
    # Why the registry refused a change a client asked for: an unknown
    # device, or an address or route the device has, lacks or has no room
    # for. These are routine answers to a client, not
    # failures, so they are returned instead of raised; *message* is the
    # text of the error reply.
    record Rejection, message : String, field : String? = nil do
      # The rejection for a device the registry does not know: one the
      # daemon did not create, or one that is gone.
      def self.unknown_device : Rejection
        new(message: Protocol::UNKNOWN_DEVICE)
      end

      # The field of the request the rejection is about; raises
      # `NilAssertionError` when it is about none.
      def field! : String
        @field || raise NilAssertionError.new("the rejection is not about a field: #{message}")
      end
    end
  end
end
