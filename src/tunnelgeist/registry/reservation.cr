{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  class Registry
    # A device slot `Registry#reserve` set aside for *owner* before the
    # device exists (RF3.2). It counts against the limits from then on, so
    # creates whose commands run at the same time cannot together exceed
    # them. `Registry#register` turns it into the slot of the new entry;
    # `Registry#release` gives it back when the create fails. The registry
    # knows its reservations by identity, so one it did not hand out, or
    # one already used, counts for nothing.
    class Reservation
      # The effective uid the slot counts against.
      getter owner : UInt32

      def initialize(@owner : UInt32)
      end
    end
  end
end
