{% skip_file unless flag?(:darwin) %}

require "./prefix"
require "./address"
require "./interface_name"
require "./key"
require "./registry/entry"
require "./registry/rejection"

module Tunnelgeist
  # The devices the helper created (UA6): name, interface index, key and the
  # addresses and routes the helper added. It lives in memory only, so after
  # a restart every key is unknown.
  class Registry
    private DUMMY_KEY = Key.new("A" * 43)

    # A registry with no device; a restarted daemon starts like this, so every
    # earlier key is unknown.
    def initialize
      @entries = {} of InterfaceName => Entry
      # Reentrant, so a block in `with_entry` may remove its own entry.
      @mutex = Mutex.new(:reentrant)
    end

    # Records a new device and returns its key. The kernel just handed out
    # *name*, so an entry already registered for it is stale: its device
    # went away without the departure watcher noticing (UA6). That entry is
    # replaced, its key stops working, and it is yielded, under the
    # registry mutex, so the caller can log the replacement.
    def register(name : InterfaceName, *, index : UInt32, addresses : Array(Address), routes : Array(Prefix),
                 & : Entry ->) : Key
      @mutex.synchronize do
        stale = @entries[name]?
        key = Key.generate
        @entries[name] = Entry.new(name: name, index: index, key: key, addresses: addresses, routes: routes)
        yield stale if stale
        key
      end
    end

    # Yields the entry of *name* while holding the registry mutex, so a
    # change and the commands it runs cannot interleave with another one,
    # and returns the value of the block. An unknown name and a wrong key
    # yield nothing and return the same `Rejection.unknown_device` (UP5).
    # The caller re-checks the interface index inside the block (UA6).
    def with_entry(name : InterfaceName, *, key : Key, & : Entry -> T) : T | Rejection forall T
      @mutex.synchronize do
        entry = @entries[name]?
        # An unknown name compares against a dummy key, so both refusals
        # do the same work.
        matched = (entry ? entry.key : DUMMY_KEY).matches?(key)
        if entry && matched
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
