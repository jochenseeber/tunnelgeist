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
  class Registry
    # A registry with no device; a restarted daemon starts like this, so every
    # earlier device is unknown.
    def initialize
      @entries = {} of InterfaceName => Entry
      # Reentrant, so a block in `with_entry` may remove its own entry.
      @mutex = Mutex.new(:reentrant)
    end

    # Records a new device. The kernel just handed out *name*, so an entry
    # already registered for it is stale: its device went away without the
    # departure watcher noticing (UA6). That entry is replaced and yielded,
    # under the registry mutex, so the caller can log the replacement.
    def register(name : InterfaceName, *, index : UInt32, addresses : Array(Address), routes : Array(Prefix),
                 & : Entry ->) : Nil
      @mutex.synchronize do
        stale = @entries[name]?
        @entries[name] = Entry.new(name: name, index: index, addresses: addresses, routes: routes)
        yield stale if stale
      end
    end

    # Yields the entry of *name* while holding the registry mutex, so a
    # change and the commands it runs cannot interleave with another one,
    # and returns the value of the block. An unknown name yields nothing and
    # returns `Rejection.unknown_device`. The caller re-checks the interface
    # index inside the block (UA6).
    def with_entry(name : InterfaceName, & : Entry -> T) : T | Rejection forall T
      @mutex.synchronize do
        entry = @entries[name]?
        if entry
          yield entry
        else
          Rejection.unknown_device
        end
      end
    end

    # Forgets the device *name*; returns whether it was registered.
    def remove(name : InterfaceName) : Bool
      @mutex.synchronize { !@entries.delete(name).nil? }
    end

    # Whether no device is registered, which lets the daemon exit when it is
    # idle.
    def empty? : Bool
      @mutex.synchronize { @entries.empty? }
    end
  end
end
