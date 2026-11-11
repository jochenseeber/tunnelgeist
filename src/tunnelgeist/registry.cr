{% skip_file unless flag?(:darwin) %}

require "./prefix"
require "./address"
require "./interface_name"
require "./registry/entry"
require "./registry/rejection"

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
  # - The registry's map lock guards only the map from name to entry. It is
  #   held for a lookup, a registration or a removal and never across a
  #   command, so a departure, a create and the daemon's idle check never
  #   wait for a change.
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
  class Registry
    # A registry with no device; a restarted daemon starts like this, so every
    # earlier device is unknown.
    def initialize
      @entries = {} of InterfaceName => Entry
      @map_lock = Mutex.new
    end

    # Records a new device. The kernel just handed out *name*, so an entry
    # already registered for it is stale: its device went away without the
    # departure watcher noticing (UA6). That entry is marked removed,
    # replaced and yielded, under the map lock, so the caller can log the
    # replacement; the block must not call the registry.
    def register(name : InterfaceName, *, index : UInt32, addresses : Array(Address), routes : Array(Prefix),
                 & : Entry ->) : Nil
      entry = Entry.new(name: name, index: index, addresses: addresses, routes: routes)
      @map_lock.synchronize do
        stale = @entries[name]?
        @entries[name] = entry
        if stale
          stale.mark_removed
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

    # Forgets the device *name* and marks its entry removed, without
    # waiting for a change that holds the entry; returns whether it was
    # registered.
    def remove(name : InterfaceName) : Bool
      @map_lock.synchronize do
        entry = @entries.delete(name)
        entry.try(&.mark_removed)
        !entry.nil?
      end
    end

    # Forgets *entry* and marks it removed, but only while it is the entry
    # registered for its name: one that a new registration replaced is
    # removed already, and its name belongs to the new device. Returns
    # whether it was registered.
    def remove(entry : Entry) : Bool
      @map_lock.synchronize do
        registered = @entries[entry.name]?.same?(entry)
        if registered
          @entries.delete(entry.name)
          entry.mark_removed
        end
        registered
      end
    end

    # Whether no device is registered, which lets the daemon exit when it is
    # idle.
    def empty? : Bool
      @map_lock.synchronize { @entries.empty? }
    end
  end
end
