{% skip_file unless flag?(:darwin) %}

require "./prefix"
require "./address"
require "./interface_name"
require "./registry/entry"
require "./registry/rejection"
require "./registry/reservation"

module Tunnelgeist
  # The devices the helper created (UA6): name, interface index and the
  # addresses and routes the helper added. It lives in memory only, so after
  # a restart every earlier device is unknown. It does not authenticate: the
  # handler lets a client change a device only with the device's own
  # descriptor (RF1.4).
  #
  # Two kinds of lock keep it consistent without letting one slow command
  # hold up other devices (RF1.6):
  #
  # - The registry's map lock guards only the map from name to entry and
  #   the count of device slots. It is held for a lookup, a reservation, a
  #   registration or a removal and never across a command, so a departure,
  #   a create and the daemon's idle check never wait for a change.
  # - Each `Entry` has a lock of its own, which `with_entry` holds for a
  #   whole change of that device: check, command and record.
  #
  # The order is entry lock, then map lock: a change may remove its own
  # entry while it holds it, but nothing waits for an entry's lock while
  # holding the map lock, and nothing holds one entry's lock while waiting
  # for another's, so the two cannot deadlock. A removal marks the entry
  # removed with a flag instead of taking its lock, so it does not wait for
  # a change that holds the entry; that change records nothing (see
  # `Entry`).
  #
  # It also bounds the devices (RF3): at most *max_devices* in total and
  # *max_devices_per_user* per owner, the effective uid of the client that
  # created them. `reserve` takes a slot before the device exists, and the
  # entry `register` makes from the reservation keeps it until the entry is
  # removed; a reservation that is never registered is released.
  class Registry
    # The most devices the daemon keeps at once.
    MAX_DEVICES = 128
    # The most devices the daemon keeps at once for one user.
    MAX_DEVICES_PER_USER = 16

    # A registry with no device; a restarted daemon starts like this, so every
    # earlier device is unknown. The daemon keeps the default limits.
    def initialize(*, @max_devices : Int32 = MAX_DEVICES, @max_devices_per_user : Int32 = MAX_DEVICES_PER_USER)
      @entries = {} of InterfaceName => Entry
      @reservations = Set(Reservation).new
      # The slots taken, per owner and in total: one per outstanding
      # reservation and one per entry. An owner without a slot has no key.
      @slots = {} of UInt32 => Int32
      @slots_taken = 0
      @map_lock = Mutex.new
    end

    # Takes a device slot for *owner* before the device is created, so
    # creates whose commands run at the same time cannot together exceed
    # the limits (RF3.2). Returns why it cannot instead: *owner* has
    # `max_devices_per_user` slots, or all `max_devices` are taken. The
    # caller registers the device with the reservation and releases it on
    # every path; `release` does nothing once `register` has used it.
    def reserve(owner : UInt32) : Reservation | Rejection
      @map_lock.synchronize do
        if @slots.fetch(owner, 0) >= @max_devices_per_user
          Rejection.new(message: "device limit of #{@max_devices_per_user} reached for uid #{owner}")
        elsif @slots_taken >= @max_devices
          Rejection.new(message: "device limit of #{@max_devices} reached")
        else
          take_slot(owner)
          reservation = Reservation.new(owner)
          @reservations << reservation
          reservation
        end
      end
    end

    # Gives the slot of *reservation* back, unless `register` used it or it
    # was released already.
    def release(reservation : Reservation) : Nil
      @map_lock.synchronize do
        free_slot(reservation.owner) if @reservations.delete(reservation)
      end
    end

    # Records a new device in the slot of *reservation*, whose owner the
    # entry keeps. The kernel just handed out *name*, so an entry already
    # registered for it is stale: its device went away without the
    # departure watcher noticing (UA6). That entry is marked removed, frees
    # its slot, is replaced and yielded, under the map lock, so the caller
    # can log the replacement; the block must not call the registry. Raises
    # `ArgumentError` when *reservation* is not one of this registry's
    # outstanding reservations.
    def register(name : InterfaceName, *, reservation : Reservation, index : UInt32, addresses : Array(Address),
                 routes : Array(Prefix), & : Entry ->) : Nil
      entry = Entry.new(name: name, index: index, owner: reservation.owner, addresses: addresses, routes: routes)
      @map_lock.synchronize do
        unless @reservations.delete(reservation)
          raise ArgumentError.new("no outstanding reservation for uid #{reservation.owner} to register #{name} in")
        end

        stale = @entries[name]?
        @entries[name] = entry
        if stale
          drop(stale)
          yield stale
        end
      end
    end

    # Yields the entry of *name* while holding the entry's lock, so the
    # changes of one device and the commands they run do not interleave,
    # and returns the value of the block. Changes of other devices, and
    # every other call of the registry, go on meanwhile. An unknown name,
    # or an entry removed while waiting for its lock, yields nothing and
    # returns `Rejection.unknown_device`. The caller re-checks the interface
    # index inside the block (UA6).
    def with_entry(name : InterfaceName, & : Entry -> T) : T | Rejection forall T
      entry = @map_lock.synchronize { @entries[name]? }
      if entry
        entry.exclusively { yield entry }
      else
        Rejection.unknown_device
      end
    end

    # Forgets the device *name*, marks its entry removed and frees its slot,
    # without waiting for a change that holds the entry; returns whether it
    # was registered.
    def remove(name : InterfaceName) : Bool
      @map_lock.synchronize do
        entry = @entries.delete(name)
        drop(entry) if entry
        !entry.nil?
      end
    end

    # Forgets *entry*, marks it removed and frees its slot, but only while it
    # is the entry registered for its name: one that a new registration
    # replaced is removed already, and its name belongs to the new device.
    # Returns whether it was registered.
    def remove(entry : Entry) : Bool
      @map_lock.synchronize do
        registered = @entries[entry.name]?.same?(entry)
        if registered
          @entries.delete(entry.name)
          drop(entry)
        end
        registered
      end
    end

    # Whether no device is registered, which lets the daemon exit when it is
    # idle.
    def empty? : Bool
      @map_lock.synchronize { @entries.empty? }
    end

    # Marks *entry*, which the caller took out of the map under the map
    # lock, removed and frees its slot.
    private def drop(entry : Entry) : Nil
      entry.mark_removed
      free_slot(entry.owner)
    end

    # Counts one more slot of *owner*; the caller holds the map lock.
    private def take_slot(owner : UInt32) : Nil
      @slots[owner] = @slots.fetch(owner, 0) + 1
      @slots_taken += 1
    end

    # Counts one slot of *owner* less; the caller holds the map lock. An
    # owner left with none is forgotten, so the map does not grow with
    # every uid that ever had a device.
    private def free_slot(owner : UInt32) : Nil
      left = @slots.fetch(owner, 0) - 1
      if left > 0
        @slots[owner] = left
      else
        @slots.delete(owner)
      end
      @slots_taken -= 1
    end
  end
end
