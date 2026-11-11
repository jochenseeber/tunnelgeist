{% skip_file unless flag?(:darwin) %}

require "../address"
require "../interface_name"
require "../prefix"
require "../protocol/common"
require "./rejection"

module Tunnelgeist
  class Registry
    # One device. It owns the arrays of what the helper added; they change
    # only under the registry's mutex, through `with_entry`.
    class Entry
      # The interface name, such as `utun7`.
      getter name : InterfaceName
      # The kernel's interface index.
      getter index : UInt32

      # Copies *addresses* and *routes*. Raises `ArgumentError` when two of
      # *addresses* have one local address: the kernel keeps one alias per
      # local address, so the entry could not tell them apart.
      def initialize(*, @name : InterfaceName, @index : UInt32, addresses : Array(Address), routes : Array(Prefix))
        addresses.each_with_index do |address, index|
          if addresses.first(index).any?(&.same_local?(address))
            raise ArgumentError.new("address #{address.address.address} listed twice")
          end
        end
        @addresses = addresses.dup
        @routes = routes.dup
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
      # and changes nothing.
      def add_address(address : Address) : Rejection?
        rejection = check_add_address(address)
        @addresses << address unless rejection
        rejection
      end

      # Forgets *address*, or returns the rejection of
      # `check_remove_address` and changes nothing.
      def remove_address(address : Address) : Rejection?
        rejection = check_remove_address(address)
        @addresses.delete(address) unless rejection
        rejection
      end

      # Records *route*, or returns the rejection of `check_add_route` and
      # changes nothing.
      def add_route(route : Prefix) : Rejection?
        rejection = check_add_route(route)
        @routes << route unless rejection
        rejection
      end

      # Forgets *route*, or returns the rejection of `check_remove_route`
      # and changes nothing.
      def remove_route(route : Prefix) : Rejection?
        rejection = check_remove_route(route)
        @routes.delete(route) unless rejection
        rejection
      end
    end
  end
end
