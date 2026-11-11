{% skip_file unless flag?(:darwin) %}

require "../address"
require "../interface_name"
require "../prefix"
require "../protocol/common"
require "./rejection"

module Tunnelgeist
  class Registry
    # One device. It owns the arrays of what the helper added; they change
    # only under the entry's own lock, through `Registry#with_entry`, so the
    # changes of one device run one at a time and those of different
    # devices do not wait for each other.
    #
    # Once the registry drops the entry (a departure, a stale entry replaced
    # or an interface index that no longer matches), it is removed: it
    # records nothing more, and each change refuses as for an unknown
    # device. That is a flag, not the lock, so the registry can drop an
    # entry while a change holds it and its command runs.
    class Entry
      # The interface name, such as `utun7`.
      getter name : InterfaceName
      # The kernel's interface index.
      getter index : UInt32
      # The effective uid of the client that created the device, whose
      # device slot the entry holds.
      getter owner : UInt32

      # Held for a whole change: check, command and record.
      @lock = Mutex.new
      @removed = Atomic(Bool).new(false)

      # Copies *addresses* and *routes*. Raises `ArgumentError` when two of
      # *addresses* have one local address: the kernel keeps one alias per
      # local address, so the entry could not tell them apart.
      def initialize(*, @name : InterfaceName, @index : UInt32, @owner : UInt32, addresses : Array(Address), routes : Array(Prefix))
        addresses.each_with_index do |address, index|
          if addresses.first(index).any?(&.same_local?(address))
            raise ArgumentError.new("address #{address.address.address} listed twice")
          end
        end
        @addresses = addresses.dup
        @routes = routes.dup
      end

      # Whether the registry dropped the entry; a removed entry records
      # nothing.
      def removed? : Bool
        @removed.get
      end

      # Marks the entry removed without waiting for a change that holds it;
      # that change records nothing once its command is done.
      protected def mark_removed : Nil
        @removed.set(true)
      end

      # Yields while holding the entry's lock and returns the value of the
      # block; yields nothing and returns `Rejection.unknown_device` when the
      # entry is removed, also when that happened while it waited for the
      # lock.
      protected def exclusively(& : -> T) : T | Rejection forall T
        @lock.synchronize do
          if removed?
            Rejection.unknown_device
          else
            yield
          end
        end
      end

      # Why *address* cannot be added: the device has an alias with its local
      # address, whatever the prefix or peer, or would exceed
      # `MAX_ADDRESSES`; nil when it can. Changes nothing, so the handler can
      # check before it runs the command.
      def check_add_address(address : Address) : Rejection?
        if @addresses.any?(&.same_local?(address))
          Rejection.new(message: "address #{address.address.address} already on #{name}", field: "address")
        elsif @addresses.size >= Protocol::MAX_ADDRESSES
          Rejection.new(message: "#{name} would have more than #{Protocol::MAX_ADDRESSES} addresses", field: "address")
        end
      end

      # Why *address* cannot be removed: the helper did not add it; nil when
      # it can. Changes nothing.
      def check_remove_address(address : Address) : Rejection?
        return if @addresses.includes?(address)

        Rejection.new(message: "address #{address.address.address} was not added by the helper", field: "address")
      end

      # Why *route* cannot be added: the device has it or would exceed
      # `MAX_ROUTES`; nil when it can. Changes nothing.
      def check_add_route(route : Prefix) : Rejection?
        if @routes.includes?(route)
          Rejection.new(message: "route #{route} already on #{name}", field: "route")
        elsif @routes.size >= Protocol::MAX_ROUTES
          Rejection.new(message: "#{name} would have more than #{Protocol::MAX_ROUTES} routes", field: "route")
        end
      end

      # Why *route* cannot be removed: the helper did not add it; nil when it
      # can. Changes nothing.
      def check_remove_route(route : Prefix) : Rejection?
        return if @routes.includes?(route)

        Rejection.new(message: "route #{route} was not added by the helper", field: "route")
      end

      # Records *address*, or returns the rejection of `check_add_address`
      # and changes nothing; returns `Rejection.unknown_device` once the
      # entry is removed.
      def add_address(address : Address) : Rejection?
        rejection = removal || check_add_address(address)
        @addresses << address unless rejection
        rejection
      end

      # Forgets *address*, or returns the rejection of
      # `check_remove_address` and changes nothing; returns
      # `Rejection.unknown_device` once the entry is removed.
      def remove_address(address : Address) : Rejection?
        rejection = removal || check_remove_address(address)
        @addresses.delete(address) unless rejection
        rejection
      end

      # Records *route*, or returns the rejection of `check_add_route` and
      # changes nothing; returns `Rejection.unknown_device` once the entry is
      # removed.
      def add_route(route : Prefix) : Rejection?
        rejection = removal || check_add_route(route)
        @routes << route unless rejection
        rejection
      end

      # Forgets *route*, or returns the rejection of `check_remove_route`
      # and changes nothing; returns `Rejection.unknown_device` once the
      # entry is removed.
      def remove_route(route : Prefix) : Rejection?
        rejection = removal || check_remove_route(route)
        @routes.delete(route) unless rejection
        rejection
      end

      # The rejection of a change of a removed entry: its device is gone or
      # replaced, so a change whose command ran while the registry dropped
      # the entry is not recorded, and the client learns that the daemon no
      # longer knows the device.
      private def removal : Rejection?
        Rejection.unknown_device if removed?
      end
    end
  end
end
