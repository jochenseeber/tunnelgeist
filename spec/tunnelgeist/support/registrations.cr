require "../../../src/tunnelgeist/registry"

# Registers devices the way the handler does, with a reservation the
# registry handed out, for the specs that need an entry to exist.
module TunnelgeistRegistrations
  extend self

  # The owner of a device the specs register, unless they name another.
  OWNER = 501_u32

  # Reserves a slot for *owner* and registers *name* in it; yields a stale
  # entry it replaces, as `Registry#register` does. Raises when the registry
  # refuses the reservation.
  def register(registry : Tunnelgeist::Registry, *, name : Tunnelgeist::InterfaceName, index : UInt32,
               addresses : Array(Tunnelgeist::Address) = [] of Tunnelgeist::Address,
               routes : Array(Tunnelgeist::Prefix) = [] of Tunnelgeist::Prefix, owner : UInt32 = OWNER,
               & : Tunnelgeist::Registry::Entry ->) : Nil
    reservation = registry.reserve(owner)
    raise "the registry refused a reservation: #{reservation.message}" if reservation.is_a?(Tunnelgeist::Registry::Rejection)

    registry.register(name, reservation: reservation, index: index, addresses: addresses, routes: routes) do |stale|
      yield stale
    end
  end

  # Registers *name* as the block form does, ignoring a stale entry.
  def register(registry : Tunnelgeist::Registry, *, name : Tunnelgeist::InterfaceName, index : UInt32,
               addresses : Array(Tunnelgeist::Address) = [] of Tunnelgeist::Address,
               routes : Array(Tunnelgeist::Prefix) = [] of Tunnelgeist::Prefix, owner : UInt32 = OWNER) : Nil
    register(registry, name: name, index: index, addresses: addresses, routes: routes, owner: owner) { }
  end
end
