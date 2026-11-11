require "../spec_helper"
require "../../src/tunnelgeist/departure_watcher"
require "./support/prompt_calls"
require "./support/registrations"

# The departure watcher of UA5 and UA6: it reads kernel events and names the
# interface of a data link detach. The specs feed it events through a pipe;
# the kernel's own event socket is an integration test.
describe TunnelgeistDepartureWatcher do
  {% if flag?(:darwin) %}
    alias DepartureWatcher = Tunnelgeist::DepartureWatcher

    include TunnelgeistPromptCalls

    # A `kern_event_msg` (sys/kern_event.h) carrying a `net_event_data`
    # (net/if_var.h), in host byte order.
    def event(code : UInt32, *, subclass : UInt32 = 2_u32, event_class : UInt32 = 1_u32, vendor : UInt32 = 1_u32,
              name : String = "utun", unit : UInt32 = 7_u32, total_size : UInt32? = nil) : Bytes
      io = IO::Memory.new
      words = [total_size || 48_u32, vendor, event_class, subclass, 42_u32, code, 0_u32, unit]
      words.each { |word| io.write_bytes(word, IO::ByteFormat::SystemEndian) }
      field = Bytes.new(16)
      field.copy_from(name.to_slice)
      io.write(field)
      io.to_slice
    end

    test "the bindings have the sizes of the SDK" do
      assert(sizeof(DepartureWatcher::LibKernelEvent::KevRequest) == 12)
      assert(sizeof(DepartureWatcher::LibKernelEvent::KernEventHeader) == DepartureWatcher::LibKernelEvent::KEV_MSG_HEADER_SIZE)
      assert(sizeof(DepartureWatcher::LibKernelEvent::NetEventData) == 24)
      assert(event(DepartureWatcher::LibKernelEvent::KEV_DL_IF_DETACHED).size == 48)
    end

    test "parse names the interface of a detached event" do
      assert(DepartureWatcher.parse(event(DepartureWatcher::LibKernelEvent::KEV_DL_IF_DETACHED)) == Tunnelgeist::InterfaceName.new("utun7"))
    end

    test "parse names the interface of a detaching event" do
      assert(DepartureWatcher.parse(event(DepartureWatcher::LibKernelEvent::KEV_DL_IF_DETACHING, name: "utun", unit: 12_u32)) == Tunnelgeist::InterfaceName.new("utun12"))
    end

    test "parse ignores an attached event" do
      assert(DepartureWatcher.parse(event(DepartureWatcher::LibKernelEvent::KEV_DL_IF_ATTACHED)).nil?)
    end

    test "parse ignores another subclass, class or vendor" do
      assert(DepartureWatcher.parse(event(DepartureWatcher::LibKernelEvent::KEV_DL_IF_DETACHED, subclass: 1_u32)).nil?)
      assert(DepartureWatcher.parse(event(DepartureWatcher::LibKernelEvent::KEV_DL_IF_DETACHED, event_class: 2_u32)).nil?)
      assert(DepartureWatcher.parse(event(DepartureWatcher::LibKernelEvent::KEV_DL_IF_DETACHED, vendor: 2_u32)).nil?)
    end

    test "parse ignores a short message" do
      assert(DepartureWatcher.parse(Bytes.new(4)).nil?)
      assert(DepartureWatcher.parse(event(DepartureWatcher::LibKernelEvent::KEV_DL_IF_DETACHED)[0, 40]).nil?)
    end

    test "parse ignores a message whose total_size exceeds the buffer or misses the data" do
      assert(DepartureWatcher.parse(event(DepartureWatcher::LibKernelEvent::KEV_DL_IF_DETACHED, total_size: 49_u32)).nil?)
      assert(DepartureWatcher.parse(event(DepartureWatcher::LibKernelEvent::KEV_DL_IF_DETACHED, total_size: 40_u32)).nil?)
    end

    test "parse ignores an event without an interface name" do
      assert(DepartureWatcher.parse(event(DepartureWatcher::LibKernelEvent::KEV_DL_IF_DETACHED, name: "")).nil?)
    end

    test "parse ignores an interface that is not a utun device" do
      assert(DepartureWatcher.parse(event(DepartureWatcher::LibKernelEvent::KEV_DL_IF_DETACHED, name: "en", unit: 0_u32)).nil?)
    end

    # A watcher reading a pipe: its write end, the registry, the log entries
    # and a channel that receives each failure reason.
    record PipeWatcher, watcher : DepartureWatcher, writer : IO::FileDescriptor, registry : Tunnelgeist::Registry,
      backend : Log::MemoryBackend, failures : Channel(String), reader : IO::FileDescriptor

    # Runs the block with a `PipeWatcher` and closes it afterwards. With
    # *blocking* the read end starts blocking, as a source the watcher must
    # make non-blocking itself.
    def with_pipe_watcher(*, blocking : Bool = false, &)
      reader, writer = IO.pipe(read_blocking: blocking)
      registry = Tunnelgeist::Registry.new
      backend = Log::MemoryBackend.new
      failures = Channel(String).new(4)
      watcher = DepartureWatcher.new(registry, log: Log.new("tunnelgeist", backend, :debug),
        on_failure: ->(reason : String) { failures.send(reason) },
        open_events: -> { reader })
      watcher.start
      begin
        yield PipeWatcher.new(watcher: watcher, writer: writer, registry: registry, backend: backend, failures: failures, reader: reader)
      ensure
        watcher.close
        writer.close
      end
    end

    def received?(channel : Channel(String), *, within : Time::Span) : String?
      select
      when reason = channel.receive
        reason
      when timeout(within)
        nil
      end
    end

    def eventually(within : Time::Span = 1.second, &) : Bool
      deadline = Time.instant + within
      until yield
        return false if Time.instant > deadline
        sleep 5.milliseconds
      end
      true
    end

    test "the watch loop removes a departed device and logs it" do
      with_pipe_watcher do |fixture|
        utun7 = Tunnelgeist::InterfaceName.new("utun7")
        utun8 = Tunnelgeist::InterfaceName.new("utun8")
        TunnelgeistRegistrations.register(fixture.registry, name: utun7, index: 12_u32, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix) { }
        TunnelgeistRegistrations.register(fixture.registry, name: utun8, index: 13_u32, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix) { }
        fixture.writer.write(event(DepartureWatcher::LibKernelEvent::KEV_DL_IF_DETACHED))

        removed = eventually { unknown?(fixture, name: utun7) }
        assert(removed)
        assert(fixture.registry.with_entry(utun8, &.index) == 13_u32)
        assert(fixture.backend.entries.any?(&.message.==("departure name=utun7 removed")))
      end
    end

    # Registers a device *name* without addresses or routes.
    def entry(fixture : PipeWatcher, *, name : Tunnelgeist::InterfaceName, index : UInt32) : Nil
      TunnelgeistRegistrations.register(fixture.registry, name: name, index: index, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix) { }
    end

    # Whether the registry has no entry for *name*.
    def unknown?(fixture : PipeWatcher, *, name : Tunnelgeist::InterfaceName) : Bool
      fixture.registry.with_entry(name) { } == Tunnelgeist::Registry::Rejection.unknown_device
    end

    # How often the watcher logged the removal of *name*.
    def removals(fixture : PipeWatcher, *, name : String) : Int32
      fixture.backend.entries.count(&.message.==("departure name=#{name} removed"))
    end

    # Lets the watcher's fiber run, then sends a departure of utun8, the
    # marker entry, and waits until it removed that: events are handled in
    # order, so by then the watcher has handled everything written before.
    # False when utun8 is still registered after a second.
    def settle(fixture : PipeWatcher) : Bool
      sleep 20.milliseconds
      fixture.writer.write(event(DepartureWatcher::LibKernelEvent::KEV_DL_IF_DETACHED, unit: 8_u32))
      eventually { unknown?(fixture, name: Tunnelgeist::InterfaceName.new("utun8")) }
    end

    test "the departure of a device whose change is under way returns at once" do
      with_pipe_watcher do |fixture|
        utun7 = Tunnelgeist::InterfaceName.new("utun7")
        entry(fixture, name: utun7, index: 30_u32)
        holding = Channel(Nil).new(1)
        gate = Channel(Nil).new
        change = later do
          fixture.registry.with_entry(utun7) do
            holding.send(nil)
            gate.receive
          end
        end
        promptly { holding.receive }

        fixture.writer.write(event(DepartureWatcher::LibKernelEvent::KEV_DL_IF_DETACHED, unit: 7_u32))
        promptly { fixture.watcher.drain }

        assert(unknown?(fixture, name: utun7))
        assert(removals(fixture, name: "utun7") == 1)
        gate.send(nil)
        awaited(change)
      end
    end

    test "start makes the event source non-blocking and drain on an empty source returns at once" do
      with_pipe_watcher(blocking: true) do |fixture|
        Fiber.yield
        # A blocking source would block the whole thread in `drain`, not
        # only this fiber, so the mode is checked before draining.
        assert(!IO::FileDescriptor.get_blocking(fixture.reader.fd))

        drained = Channel(Nil).new(1)
        spawn do
          fixture.watcher.drain
          drained.send(nil)
        end
        returned = select
        when drained.receive
          true
        when timeout(1.second)
          false
        end

        assert(returned)
        assert(received?(fixture.failures, within: 20.milliseconds).nil?)
      end
    end

    test "without a drain, a detach event read after a new create took the name removes the new entry, which fails closed" do
      with_pipe_watcher do |fixture|
        utun7 = Tunnelgeist::InterfaceName.new("utun7")
        Fiber.yield
        entry(fixture, name: utun7, index: 30_u32)
        entry(fixture, name: Tunnelgeist::InterfaceName.new("utun8"), index: 31_u32)
        # The old device's event is buffered, and the new device registers
        # under the recycled name before the watcher reads it.
        fixture.writer.write(event(DepartureWatcher::LibKernelEvent::KEV_DL_IF_DETACHED, unit: 7_u32))
        entry(fixture, name: utun7, index: 32_u32)

        assert(settle(fixture))
        assert(unknown?(fixture, name: utun7))
        assert(removals(fixture, name: "utun7") == 1)
      end
    end

    test "with a drain before the new create registers, the detach event of the old device leaves the new entry" do
      with_pipe_watcher do |fixture|
        utun7 = Tunnelgeist::InterfaceName.new("utun7")
        Fiber.yield
        entry(fixture, name: utun7, index: 30_u32)
        entry(fixture, name: Tunnelgeist::InterfaceName.new("utun8"), index: 31_u32)
        # Nothing yields between the write and the drain, so the watcher's
        # fiber has not read the event.
        fixture.writer.write(event(DepartureWatcher::LibKernelEvent::KEV_DL_IF_DETACHED, unit: 7_u32))
        fixture.watcher.drain
        entry(fixture, name: utun7, index: 32_u32)

        assert(settle(fixture))
        assert(fixture.registry.with_entry(utun7, &.index) == 32_u32)
        assert(removals(fixture, name: "utun7") == 1)
        assert(received?(fixture.failures, within: 20.milliseconds).nil?)
      end
    end

    test "a drain that finds the event stream ended reports the failure once and does not raise" do
      with_pipe_watcher do |fixture|
        fixture.writer.close
        fixture.watcher.drain
        reason = received?(fixture.failures, within: 1.second)

        assert(reason == "kernel event socket closed")
        # The watcher's fiber sees the same end and does not report it again.
        assert(received?(fixture.failures, within: 50.milliseconds).nil?)
      end
    end

    test "a read that fails with another errno than EAGAIN is a failure" do
      reader, writer = IO.pipe
      failures = Channel(String).new(4)
      # Reading the write end of a pipe fails with EBADF.
      watcher = DepartureWatcher.new(Tunnelgeist::Registry.new, log: Log.new("tunnelgeist", Log::MemoryBackend.new, :debug),
        on_failure: ->(reason : String) { failures.send(reason) },
        open_events: -> { writer }).start
      begin
        watcher.drain
        reason = received?(failures, within: 1.second)

        assert(reason.to_s.starts_with?("IO::Error: read "))
        assert(reason.to_s.ends_with?(": Bad file descriptor"))
      ensure
        watcher.close
        reader.close
      end
    end

    test "an exception from on_failure in drain is raised, not swallowed" do
      reader, writer = IO.pipe
      watcher = DepartureWatcher.new(Tunnelgeist::Registry.new, log: Log.new("tunnelgeist", Log::MemoryBackend.new, :debug),
        on_failure: ->(_reason : String) { raise ArgumentError.new("on_failure broke") },
        open_events: -> { reader }).start
      begin
        writer.close
        assert_raises(ArgumentError) { watcher.drain }
      ensure
        watcher.close
      end
    end

    test "the end of the event stream is a failure" do
      with_pipe_watcher do |fixture|
        fixture.writer.close
        reason = received?(fixture.failures, within: 1.second)

        assert(reason == "kernel event socket closed")
        assert(fixture.backend.entries.any? { |entry| entry.severity.error? && entry.message.includes?("departure watcher stopped") })
      end
    end

    test "a read error is a failure" do
      with_pipe_watcher do |fixture|
        Fiber.yield
        fixture.reader.close
        reason = received?(fixture.failures, within: 1.second)

        assert(reason.to_s.includes?("IO::Error"))
      end
    end

    test "close stops the watcher without a failure" do
      with_pipe_watcher do |fixture|
        Fiber.yield
        fixture.watcher.close
        reason = received?(fixture.failures, within: 100.milliseconds)

        assert(reason.nil?)
      end
    end
  {% end %}
end
