require "../spec_helper"
require "../../src/tunnelgeist/registry"
require "./support/prompt_calls"
require "./support/registrations"

# The registry of the devices the helper created (UA6, UP3 to UP5).
describe TunnelgeistRegistry do
  {% if flag?(:darwin) %}
    alias Protocol = Tunnelgeist::Protocol

    include TunnelgeistPromptCalls

    def v4(last : Int32 = 1) : Tunnelgeist::Address
      Tunnelgeist::Address.new(
        Socket::IPAddress.new("10.77.0.#{last}", 0), prefix: 24, peer: Socket::IPAddress.new("10.77.1.#{last}", 0))
    end

    def route(text : String) : Tunnelgeist::Prefix
      Tunnelgeist::Prefix.parse(text)
    end

    # A stale entry as `register` yielded it.
    record Replaced, name : Tunnelgeist::InterfaceName, index : UInt32, route_recorded : Bool

    def ifname(text : String) : Tunnelgeist::InterfaceName
      Tunnelgeist::InterfaceName.new(text)
    end

    # Whether *entry* has recorded *address*: it may be removed and may not
    # be added again. `Entry` keeps its arrays to itself, so its checks
    # are what shows them.
    def recorded?(entry : Tunnelgeist::Registry::Entry, *, address : Tunnelgeist::Address) : Bool
      entry.check_remove_address(address).nil? && !entry.check_add_address(address).nil?
    end

    # Whether *entry* has recorded *route*, as for an address.
    def recorded?(entry : Tunnelgeist::Registry::Entry, *, route : Tunnelgeist::Prefix) : Bool
      entry.check_remove_route(route).nil? && !entry.check_add_route(route).nil?
    end

    # Yields the entry of *name* and fails the test when the registry
    # refuses it, so the assertions in the block cannot be skipped.
    def within_entry(registry : Tunnelgeist::Registry, *, name : Tunnelgeist::InterfaceName,
                     & : Tunnelgeist::Registry::Entry ->) : Nil
      rejection = registry.with_entry(name) do |entry|
        yield entry
        nil
      end
      assert(rejection.nil?)
    end

    # The message of *rejection*, nil when there is none.
    def refusal(rejection : Tunnelgeist::Registry::Rejection?) : String?
      rejection.try(&.message)
    end

    test "register records an entry that with_entry yields" do
      registry = Tunnelgeist::Registry.new
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [v4], routes: [route("10.99.0.0/16")]) { }

      assert(!registry.empty?)

      within_entry(registry, name: ifname("utun7")) do |entry|
        assert(entry.name == ifname("utun7"))
        assert(entry.index == 12_u32)
        assert(recorded?(entry, address: v4))
        assert(recorded?(entry, route: route("10.99.0.0/16")))
      end
    end

    test "register replaces a stale entry of the same name and yields it" do
      registry = Tunnelgeist::Registry.new
      empty_addresses = [] of Tunnelgeist::Address
      empty_routes = [] of Tunnelgeist::Prefix
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: empty_addresses, routes: [route("10.99.0.0/16")]) { }

      replaced = [] of Replaced
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 13_u32, addresses: empty_addresses, routes: empty_routes) do |stale|
        replaced << Replaced.new(name: stale.name, index: stale.index, route_recorded: recorded?(stale, route: route("10.99.0.0/16")))
      end

      assert(replaced == [Replaced.new(name: ifname("utun7"), index: 12_u32, route_recorded: true)])
      within_entry(registry, name: ifname("utun7")) do |entry|
        assert(entry.index == 13_u32)
        assert(!recorded?(entry, route: route("10.99.0.0/16")))
      end
    end

    test "register yields nothing for a name that is not registered" do
      registry = Tunnelgeist::Registry.new
      yielded = false

      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix) do
        yielded = true
      end

      assert(!yielded)
    end

    test "with_entry yields nothing for an unknown name and returns UNKNOWN_DEVICE" do
      registry = Tunnelgeist::Registry.new
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix) { }
      yielded = false

      unknown = registry.with_entry(ifname("utun8")) { yielded = true }

      assert(!yielded)
      assert(unknown == Tunnelgeist::Registry::Rejection.unknown_device)
      assert(refusal(unknown.as(Tunnelgeist::Registry::Rejection)) == Protocol::UNKNOWN_DEVICE)
      assert(Tunnelgeist::Registry::Rejection.unknown_device.field.nil?)
    end

    test "a rejection of a change names the field it is about" do
      registry = Tunnelgeist::Registry.new
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [v4(1)], routes: [route("10.99.0.0/16")]) { }

      within_entry(registry, name: ifname("utun7")) do |entry|
        assert(entry.check_add_address(v4(1)).try(&.field!) == "address")
        assert(entry.check_remove_address(v4(3)).try(&.field!) == "address")
        assert(entry.check_add_route(route("10.99.0.0/16")).try(&.field!) == "route")
        assert(entry.check_remove_route(route("10.50.0.0/16")).try(&.field!) == "route")
      end
      assert(raised(NilAssertionError) { Tunnelgeist::Registry::Rejection.unknown_device.field! }.message.to_s.includes?(Protocol::UNKNOWN_DEVICE))
    end

    test "with_entry returns the value of the block" do
      registry = Tunnelgeist::Registry.new
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix) { }

      assert(registry.with_entry(ifname("utun7"), &.name) == ifname("utun7"))
    end

    test "a block in with_entry may remove its own entry" do
      registry = Tunnelgeist::Registry.new
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix) { }

      within_entry(registry, name: ifname("utun7")) do |entry|
        registry.remove(entry.name)
        assert(registry.empty?)
      end

      assert(refusal(registry.with_entry(ifname("utun7")) { }) == Protocol::UNKNOWN_DEVICE)
    end

    test "while a block holds one entry, the registry serves every other call at once" do
      registry = Tunnelgeist::Registry.new
      empty_addresses = [] of Tunnelgeist::Address
      empty_routes = [] of Tunnelgeist::Prefix
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: empty_addresses, routes: empty_routes) { }
      TunnelgeistRegistrations.register(registry, ifname("utun8"), index: 13_u32, addresses: empty_addresses, routes: empty_routes) { }

      within_entry(registry, name: ifname("utun7")) do
        assert(promptly { registry.with_entry(ifname("utun8"), &.index) } == 13_u32)
        promptly { TunnelgeistRegistrations.register(registry, ifname("utun9"), index: 14_u32, addresses: empty_addresses, routes: empty_routes) { } }
        assert(promptly { registry.remove(ifname("utun8")) })
        assert(!promptly { registry.empty? })
      end

      assert(registry.with_entry(ifname("utun9"), &.index) == 14_u32)
    end

    test "a removal of an entry a block holds returns at once and the entry records nothing more" do
      registry = Tunnelgeist::Registry.new
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [v4(1)], routes: [route("10.99.0.0/16")]) { }

      within_entry(registry, name: ifname("utun7")) do |entry|
        assert(promptly { registry.remove(ifname("utun7")) })

        assert(refusal(entry.add_address(v4(2))) == Protocol::UNKNOWN_DEVICE)
        assert(refusal(entry.remove_address(v4(1))) == Protocol::UNKNOWN_DEVICE)
        assert(refusal(entry.add_route(route("10.98.0.0/16"))) == Protocol::UNKNOWN_DEVICE)
        assert(refusal(entry.remove_route(route("10.99.0.0/16"))) == Protocol::UNKNOWN_DEVICE)
        assert(recorded?(entry, address: v4(1)))
        assert(!recorded?(entry, address: v4(2)))
        assert(recorded?(entry, route: route("10.99.0.0/16")))
        assert(!recorded?(entry, route: route("10.98.0.0/16")))
      end
      assert(registry.empty?)
    end

    test "with_entry yields nothing when the entry is removed while it waits for the entry" do
      registry = Tunnelgeist::Registry.new
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix) { }
      yielded = false
      waiter = Channel(Tunnelgeist::Registry::Rejection | Bool | Exception).new(1)

      within_entry(registry, name: ifname("utun7")) do
        waiter = later { registry.with_entry(ifname("utun7")) { yielded = true } }
        # Lets the waiter look the entry up and wait for it.
        Fiber.yield
        registry.remove(ifname("utun7"))
      end

      assert(awaited(waiter) == Tunnelgeist::Registry::Rejection.unknown_device)
      assert(!yielded)
    end

    test "a stale entry that register replaces records nothing more" do
      registry = Tunnelgeist::Registry.new
      empty_addresses = [] of Tunnelgeist::Address
      empty_routes = [] of Tunnelgeist::Prefix
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: empty_addresses, routes: empty_routes) { }
      stale = registry.with_entry(ifname("utun7"), &.itself).as(Tunnelgeist::Registry::Entry)

      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 13_u32, addresses: empty_addresses, routes: empty_routes) { }

      assert(refusal(stale.add_route(route("10.98.0.0/16"))) == Protocol::UNKNOWN_DEVICE)
      assert(registry.with_entry(ifname("utun7")) { |entry| recorded?(entry, route: route("10.98.0.0/16")) } == false)
    end

    test "remove of an entry forgets it only while it is the registered entry of its name" do
      registry = Tunnelgeist::Registry.new
      empty_addresses = [] of Tunnelgeist::Address
      empty_routes = [] of Tunnelgeist::Prefix
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: empty_addresses, routes: empty_routes) { }
      stale = registry.with_entry(ifname("utun7"), &.itself).as(Tunnelgeist::Registry::Entry)
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 13_u32, addresses: empty_addresses, routes: empty_routes) { }
      current = registry.with_entry(ifname("utun7"), &.itself).as(Tunnelgeist::Registry::Entry)

      assert(!registry.remove(stale))
      assert(registry.with_entry(ifname("utun7"), &.index) == 13_u32)
      assert(registry.remove(current))
      assert(registry.empty?)
      assert(refusal(current.add_route(route("10.98.0.0/16"))) == Protocol::UNKNOWN_DEVICE)
    end

    test "remove forgets the entry" do
      registry = Tunnelgeist::Registry.new
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix) { }

      registry.remove(ifname("utun7"))

      assert(registry.empty?)
      assert(refusal(registry.with_entry(ifname("utun7")) { }) == Protocol::UNKNOWN_DEVICE)
      registry.remove(ifname("utun7"))
    end

    test "a name can be registered again after remove" do
      registry = Tunnelgeist::Registry.new
      empty_addresses = [] of Tunnelgeist::Address
      empty_routes = [] of Tunnelgeist::Prefix
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: empty_addresses, routes: empty_routes) { }
      registry.remove(ifname("utun7"))
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 14_u32, addresses: empty_addresses, routes: empty_routes) { }

      assert(registry.with_entry(ifname("utun7"), &.index) == 14_u32)
    end

    test "add_address and remove_address track what the helper added" do
      registry = Tunnelgeist::Registry.new
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [v4(1)], routes: [] of Tunnelgeist::Prefix) { }

      within_entry(registry, name: ifname("utun7")) do |entry|
        assert(entry.add_address(v4(2)).nil?)
        assert(recorded?(entry, address: v4(1)))
        assert(recorded?(entry, address: v4(2)))
        assert(entry.remove_address(v4(1)).nil?)
        assert(!recorded?(entry, address: v4(1)))
        assert(recorded?(entry, address: v4(2)))
      end
    end

    test "add_address refuses one the device has and remove_address one it does not" do
      registry = Tunnelgeist::Registry.new
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [v4(1)], routes: [] of Tunnelgeist::Prefix) { }

      within_entry(registry, name: ifname("utun7")) do |entry|
        assert(refusal(entry.add_address(v4(1))) == "address 10.77.0.1 already on utun7")
        assert(refusal(entry.remove_address(v4(3))) == "address 10.77.0.3 was not added by the helper")
        assert(recorded?(entry, address: v4(1)))
        assert(!recorded?(entry, address: v4(3)))
      end
    end

    test "an address is identified by its local address, whatever its prefix or peer" do
      registry = Tunnelgeist::Registry.new
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [v4(1)], routes: [] of Tunnelgeist::Prefix) { }
      other_prefix = Tunnelgeist::Address.new(
        Socket::IPAddress.new("10.77.0.1", 0), prefix: 25, peer: Socket::IPAddress.new("10.77.1.1", 0))
      other_peer = Tunnelgeist::Address.new(
        Socket::IPAddress.new("10.77.0.1", 0), prefix: 24, peer: Socket::IPAddress.new("10.77.1.9", 0))

      within_entry(registry, name: ifname("utun7")) do |entry|
        assert(refusal(entry.add_address(other_prefix)) == "address 10.77.0.1 already on utun7")
        assert(refusal(entry.add_address(other_peer)) == "address 10.77.0.1 already on utun7")
        assert(refusal(entry.add_address(v4(1))) == "address 10.77.0.1 already on utun7")
        # Removal stays an exact match on the recorded alias.
        assert(refusal(entry.remove_address(other_prefix)) == "address 10.77.0.1 was not added by the helper")
        assert(entry.remove_address(v4(1)).nil?)
        assert(entry.add_address(other_prefix).nil?)
      end
    end

    test "register refuses addresses that share a local address" do
      registry = Tunnelgeist::Registry.new
      other_prefix = Tunnelgeist::Address.new(
        Socket::IPAddress.new("10.77.0.1", 0), prefix: 25, peer: Socket::IPAddress.new("10.77.1.1", 0))

      error = raised(ArgumentError) do
        TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [v4(1), other_prefix], routes: [] of Tunnelgeist::Prefix) { }
      end
      assert(error.message == "address 10.77.0.1 listed twice")
    end

    test "add_route and remove_route track what the helper added" do
      registry = Tunnelgeist::Registry.new
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [] of Tunnelgeist::Address, routes: [route("10.99.0.0/16")]) { }

      within_entry(registry, name: ifname("utun7")) do |entry|
        assert(entry.add_route(route("10.98.0.0/16")).nil?)
        assert(recorded?(entry, route: route("10.99.0.0/16")))
        assert(recorded?(entry, route: route("10.98.0.0/16")))
        assert(entry.remove_route(route("10.99.0.0/16")).nil?)
        assert(!recorded?(entry, route: route("10.99.0.0/16")))
        assert(recorded?(entry, route: route("10.98.0.0/16")))
      end
    end

    test "add_route refuses a route the device has and remove_route a foreign one" do
      registry = Tunnelgeist::Registry.new
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [] of Tunnelgeist::Address, routes: [route("10.99.0.0/16")]) { }

      within_entry(registry, name: ifname("utun7")) do |entry|
        assert(refusal(entry.add_route(route("10.99.0.0/16"))) == "route 10.99.0.0/16 already on utun7")
        assert(refusal(entry.remove_route(route("10.50.0.0/16"))) == "route 10.50.0.0/16 was not added by the helper")
        assert(refusal(entry.remove_route(route("10.99.0.0/24"))) == "route 10.99.0.0/24 was not added by the helper")
        assert(recorded?(entry, route: route("10.99.0.0/16")))
        assert(!recorded?(entry, route: route("10.99.0.0/24")))
      end
    end

    test "a route of the same prefix on another device is not removable" do
      registry = Tunnelgeist::Registry.new
      empty_addresses = [] of Tunnelgeist::Address
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: empty_addresses, routes: [route("10.99.0.0/16")]) { }
      TunnelgeistRegistrations.register(registry, ifname("utun8"), index: 13_u32, addresses: empty_addresses, routes: [] of Tunnelgeist::Prefix) { }

      within_entry(registry, name: ifname("utun8")) do |entry|
        assert(refusal(entry.remove_route(route("10.99.0.0/16"))) == "route 10.99.0.0/16 was not added by the helper")
      end
      assert(registry.with_entry(ifname("utun7")) { |entry| recorded?(entry, route: route("10.99.0.0/16")) } == true)
    end

    test "the address total counts the addresses the device already has" do
      registry = Tunnelgeist::Registry.new
      existing = (1..15).map { |last| v4(last) }
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: existing, routes: [] of Tunnelgeist::Prefix) { }

      within_entry(registry, name: ifname("utun7")) do |entry|
        assert(entry.add_address(v4(16)).nil?)
        assert(recorded?(entry, address: v4(16)))
        assert(refusal(entry.add_address(v4(17))) == "utun7 would have more than 16 addresses")
        assert(!recorded?(entry, address: v4(17)))
      end
    end

    test "the route total counts the routes the device already has" do
      registry = Tunnelgeist::Registry.new
      existing = (1..63).map { |third| route("10.#{third}.0.0/16") }
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [] of Tunnelgeist::Address, routes: existing) { }

      within_entry(registry, name: ifname("utun7")) do |entry|
        assert(entry.add_route(route("10.100.0.0/16")).nil?)
        assert(recorded?(entry, route: route("10.100.0.0/16")))
        assert(refusal(entry.add_route(route("10.101.0.0/16"))) == "utun7 would have more than 64 routes")
        assert(!recorded?(entry, route: route("10.101.0.0/16")))
      end
    end

    test "changes made inside with_entry persist" do
      registry = Tunnelgeist::Registry.new
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix) { }

      registry.with_entry(ifname("utun7"), &.add_route(route("10.99.0.0/16")))

      assert(registry.with_entry(ifname("utun7")) { |entry| recorded?(entry, route: route("10.99.0.0/16")) } == true)
    end

    test "the check methods refuse what the change would refuse and change nothing" do
      registry = Tunnelgeist::Registry.new
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [v4(1)], routes: [route("10.99.0.0/16")]) { }

      within_entry(registry, name: ifname("utun7")) do |entry|
        assert(refusal(entry.check_add_address(v4(1))) == "address 10.77.0.1 already on utun7")
        assert(refusal(entry.check_remove_address(v4(3))) == "address 10.77.0.3 was not added by the helper")
        assert(refusal(entry.check_add_route(route("10.99.0.0/16"))) == "route 10.99.0.0/16 already on utun7")
        assert(refusal(entry.check_remove_route(route("10.50.0.0/16"))) ==
               "route 10.50.0.0/16 was not added by the helper")
        assert(recorded?(entry, address: v4(1)))
        assert(!recorded?(entry, address: v4(3)))
        assert(recorded?(entry, route: route("10.99.0.0/16")))
        assert(!recorded?(entry, route: route("10.50.0.0/16")))
      end
    end

    test "the check methods accept a valid change without making it" do
      registry = Tunnelgeist::Registry.new
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: [v4(1)], routes: [route("10.99.0.0/16")]) { }

      within_entry(registry, name: ifname("utun7")) do |entry|
        assert(entry.check_add_address(v4(2)).nil?)
        assert(entry.check_remove_address(v4(1)).nil?)
        assert(entry.check_add_route(route("10.98.0.0/16")).nil?)
        assert(entry.check_remove_route(route("10.99.0.0/16")).nil?)
        assert(recorded?(entry, address: v4(1)))
        assert(!recorded?(entry, address: v4(2)))
        assert(recorded?(entry, route: route("10.99.0.0/16")))
        assert(!recorded?(entry, route: route("10.98.0.0/16")))
      end
    end

    test "the check methods refuse a change over the totals" do
      registry = Tunnelgeist::Registry.new
      addresses = (1..16).map { |last| v4(last) }
      routes = (1..64).map { |third| route("10.#{third}.0.0/16") }
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, addresses: addresses, routes: routes) { }

      within_entry(registry, name: ifname("utun7")) do |entry|
        assert(refusal(entry.check_add_address(v4(17))) == "utun7 would have more than 16 addresses")
        assert(refusal(entry.check_add_route(route("10.101.0.0/16"))) == "utun7 would have more than 64 routes")
      end
    end

    # The device limits (RF3).

    # A reservation of *registry* for *owner*; fails the test when the
    # registry refuses it.
    def reserved(registry : Tunnelgeist::Registry, *, owner : UInt32) : Tunnelgeist::Registry::Reservation
      reservation = registry.reserve(owner)
      raise "reservation refused: #{reservation.message}" if reservation.is_a?(Tunnelgeist::Registry::Rejection)

      reservation
    end

    # The message of the rejection `reserve` returns for *owner*, nil when it
    # reserves a slot; that slot is released again.
    def reserve_refusal(registry : Tunnelgeist::Registry, *, owner : UInt32) : String?
      reservation = registry.reserve(owner)
      if reservation.is_a?(Tunnelgeist::Registry::Rejection)
        reservation.message
      else
        registry.release(reservation)
        nil
      end
    end

    test "the default limits are 128 devices and 16 per user" do
      assert(Tunnelgeist::Registry::MAX_DEVICES == 128)
      assert(Tunnelgeist::Registry::MAX_DEVICES_PER_USER == 16)
      registry = Tunnelgeist::Registry.new
      16.times { |unit| TunnelgeistRegistrations.register(registry, ifname("utun#{unit}"), index: unit.to_u32 + 1, owner: 501_u32) }

      assert(reserve_refusal(registry, owner: 501_u32) == "device limit of 16 reached for uid 501")
    end

    test "reserve refuses an owner at the per-user limit and admits another owner" do
      registry = Tunnelgeist::Registry.new(max_devices: 10, max_devices_per_user: 2)
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, owner: 501_u32)
      TunnelgeistRegistrations.register(registry, ifname("utun8"), index: 13_u32, owner: 501_u32)

      assert(reserve_refusal(registry, owner: 501_u32) == "device limit of 2 reached for uid 501")
      assert(reserve_refusal(registry, owner: 502_u32).nil?)
    end

    test "reserve refuses every owner at the total limit" do
      registry = Tunnelgeist::Registry.new(max_devices: 2, max_devices_per_user: 2)
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, owner: 501_u32)
      TunnelgeistRegistrations.register(registry, ifname("utun8"), index: 13_u32, owner: 502_u32)

      assert(reserve_refusal(registry, owner: 501_u32) == "device limit of 2 reached")
      assert(reserve_refusal(registry, owner: 503_u32) == "device limit of 2 reached")
    end

    test "outstanding reservations count against the limits until released" do
      registry = Tunnelgeist::Registry.new(max_devices: 2, max_devices_per_user: 2)
      first = reserved(registry, owner: 501_u32)
      reserved(registry, owner: 502_u32)

      assert(reserve_refusal(registry, owner: 503_u32) == "device limit of 2 reached")
      registry.release(first)
      assert(reserve_refusal(registry, owner: 503_u32).nil?)
      # A second release gives nothing back.
      registry.release(first)
      assert(reserve_refusal(registry, owner: 503_u32).nil?)
      reserved(registry, owner: 503_u32)
      assert(reserve_refusal(registry, owner: 504_u32) == "device limit of 2 reached")
    end

    test "register keeps the slot of the reservation for the entry and records its owner" do
      registry = Tunnelgeist::Registry.new(max_devices: 1, max_devices_per_user: 1)
      reservation = reserved(registry, owner: 501_u32)

      registry.register(ifname("utun7"), reservation: reservation, index: 12_u32, addresses: [] of Tunnelgeist::Address,
        routes: [] of Tunnelgeist::Prefix) { }
      registry.release(reservation)

      assert(registry.with_entry(ifname("utun7"), &.owner) == 501_u32)
      assert(reserve_refusal(registry, owner: 501_u32) == "device limit of 1 reached for uid 501")
    end

    test "register refuses a reservation that is used or released" do
      registry = Tunnelgeist::Registry.new
      used = reserved(registry, owner: 501_u32)
      registry.register(ifname("utun7"), reservation: used, index: 12_u32, addresses: [] of Tunnelgeist::Address,
        routes: [] of Tunnelgeist::Prefix) { }
      released = reserved(registry, owner: 501_u32)
      registry.release(released)

      [used, released].each do |reservation|
        error = raised(ArgumentError) do
          registry.register(ifname("utun8"), reservation: reservation, index: 13_u32, addresses: [] of Tunnelgeist::Address,
            routes: [] of Tunnelgeist::Prefix) { }
        end
        assert(error.message == "no outstanding reservation for uid 501 to register utun8 in")
      end
      assert(registry.with_entry(ifname("utun8")) { } == Tunnelgeist::Registry::Rejection.unknown_device)
    end

    test "register with addresses an entry refuses gives the reservation back to release" do
      registry = Tunnelgeist::Registry.new(max_devices: 1, max_devices_per_user: 1)
      reservation = reserved(registry, owner: 501_u32)

      raised(ArgumentError) do
        registry.register(ifname("utun7"), reservation: reservation, index: 12_u32, addresses: [v4(1), v4(1)],
          routes: [] of Tunnelgeist::Prefix) { }
      end
      registry.release(reservation)

      assert(registry.empty?)
      assert(reserve_refusal(registry, owner: 501_u32).nil?)
    end

    test "remove by name frees the slot of the entry, as a departure does" do
      registry = Tunnelgeist::Registry.new(max_devices: 1, max_devices_per_user: 1)
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, owner: 501_u32)

      assert(registry.remove(ifname("utun7")))
      assert(reserve_refusal(registry, owner: 501_u32).nil?)
      # Removing it again frees nothing more.
      assert(!registry.remove(ifname("utun7")))
      reserved(registry, owner: 501_u32)
      assert(reserve_refusal(registry, owner: 502_u32) == "device limit of 1 reached")
    end

    test "remove of an entry frees its slot once, and a replaced entry frees nothing more" do
      registry = Tunnelgeist::Registry.new(max_devices: 2, max_devices_per_user: 2)
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, owner: 501_u32)
      stale = registry.with_entry(ifname("utun7"), &.itself).as(Tunnelgeist::Registry::Entry)
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 13_u32, owner: 502_u32)
      current = registry.with_entry(ifname("utun7"), &.itself).as(Tunnelgeist::Registry::Entry)

      # The replacement freed the slot of 501's stale entry.
      assert(reserve_refusal(registry, owner: 501_u32).nil?)
      assert(!registry.remove(stale))
      reserved(registry, owner: 501_u32)
      assert(reserve_refusal(registry, owner: 503_u32) == "device limit of 2 reached")

      assert(registry.remove(current))
      assert(reserve_refusal(registry, owner: 503_u32).nil?)
    end

    test "a stale entry that register replaces frees its owner's slot" do
      registry = Tunnelgeist::Registry.new(max_devices: 10, max_devices_per_user: 2)
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 12_u32, owner: 501_u32)
      TunnelgeistRegistrations.register(registry, ifname("utun7"), index: 13_u32, owner: 501_u32)

      reserved(registry, owner: 501_u32)
      assert(reserve_refusal(registry, owner: 501_u32) == "device limit of 2 reached for uid 501")
    end
  {% end %}
end
