{% skip_file unless flag?(:darwin) %}

require "log"
require "./departure_watcher/lib_kernel_event"
require "./device/lib_utun"
require "./interface_name"
require "./registry"

module Tunnelgeist
  # Removes a device from the registry when its interface goes away (UA5,
  # UA6), so the next client that gets the recycled unit `utunN` does not
  # find a key that still works. The removal is unconditional: Darwin can
  # reuse the interface index together with the unit, so a matching index
  # does not prove the entry's device is still alive, and keeping the entry
  # would fail open. When a new `create` took the name before the event was
  # read, that device loses its key, and its client's next change gets
  # `unknown device or wrong key` and must create a device again.
  #
  # The design names the routing socket's `RTM_IFANNOUNCE` message, but that
  # is FreeBSD's: macOS declares neither it nor `struct if_announcemsghdr`
  # in any SDK, and its routing socket sends no message when an interface
  # is detached. macOS reports that as a kernel event instead, so the
  # watcher reads a `PF_SYSTEM` / `SYSPROTO_EVENT` socket filtered to
  # Apple's data link events.
  #
  # Both `KEV_DL_IF_DETACHING` and `KEV_DL_IF_DETACHED` count as a
  # departure: the kernel posts the first when the detach starts and the
  # second when it is done, and either means the device is going away.
  # Removing an unknown name does nothing, so counting both removes the
  # entry as early as possible and still removes it when only one is seen.
  #
  # `drain` closes the race of a recycled name without comparing indexes:
  # the handler calls it after a new device exists and before registering
  # it, so every event about the previous owner of the name is handled
  # first, and nothing stale is left to remove the new entry. That rests on
  # an assumption, unverified because probing it needs root: the kernel
  # hands `utunN` to a new `create` only after the previous interface is
  # fully detached, and the `KEV_DL_IF_DETACHED` of that detach is readable
  # on the event socket before the `create` returns.
  #
  # The event source is non-blocking. The watcher's fiber waits until it is
  # readable without holding the mutex, then reads every buffered event
  # under it; `drain` reads under the same mutex, so the two never
  # interleave and events are handled in the order the kernel posted them.
  class DepartureWatcher
    # Room for one kernel event; data link events are 48 bytes.
    BUFFER_SIZE = 1_024

    @io : IO::FileDescriptor?

    @closing = false

    @failed = false

    # Held while events are read, by the watcher's fiber and by `drain`.
    @reading = Mutex.new

    # *on_failure* runs with the reason when the watcher stops on its own
    # (a read error, or the socket ending). The daemon must stop then: it
    # would no longer notice departures, and a restart makes every key
    # unknown, which fails closed.
    # *open_events* opens the source of kernel events, one event per read;
    # by default the kernel event socket. The specs replace it.
    def initialize(@registry : Registry, *, @log : Log, @on_failure : (String ->)? = nil,
                   @open_events : -> IO::FileDescriptor = -> { open_kernel_events })
    end

    # The interface name of a data link detach event in *message*, a
    # `kern_event_msg`; nil for any other event, for an interface that is
    # not a utun device and for a message shorter than its `total_size` or
    # than a header and a `net_event_data`.
    def self.parse(message : Bytes) : InterfaceName?
      data_size = sizeof(LibKernelEvent::NetEventData)
      return if message.size < (LibKernelEvent::KEV_MSG_HEADER_SIZE + data_size)

      total_size = read_word(message, offset: 0)
      return if (total_size > message.size) || (total_size < (LibKernelEvent::KEV_MSG_HEADER_SIZE + data_size))
      return unless read_word(message, offset: 4) == LibKernelEvent::KEV_VENDOR_APPLE
      return unless read_word(message, offset: 8) == LibKernelEvent::KEV_NETWORK_CLASS
      return unless read_word(message, offset: 12) == LibKernelEvent::KEV_DL_SUBCLASS

      code = read_word(message, offset: 20)
      return unless (code == LibKernelEvent::KEV_DL_IF_DETACHING) || (code == LibKernelEvent::KEV_DL_IF_DETACHED)

      data = message[LibKernelEvent::KEV_MSG_HEADER_SIZE, data_size]
      field = data[8, Device::LibUtun::IFNAMSIZ]
      name = String.new(field[0, field.index(0_u8) || field.size])
      return if name.empty?

      InterfaceName.parse?("#{name}#{read_word(data, offset: 4)}")
    end

    private def self.read_word(bytes : Bytes, *, offset : Int32) : UInt32
      IO::ByteFormat::SystemEndian.decode(UInt32, bytes[offset, 4])
    end

    # Opens the event source and reads it in a fiber. Raises `IO::Error`
    # when the kernel event socket cannot be opened or filtered. Returns
    # `self`.
    def start : self
      io = @open_events.call
      # `drain` must never wait for an event, whatever source was opened.
      IO::FileDescriptor.set_blocking(io.fd, false)
      @io = io
      spawn(name: "tunnelgeist.departure") { watch(io) }
      self
    end

    # Handles every event buffered in the event source at the time of the
    # call and returns; it never waits for an event. The handler calls it
    # between creating a device and registering it. A failure, such as the
    # source having ended, reaches *on_failure* as in the watcher's fiber
    # and is not raised: *on_failure* stops the daemon, and every key with
    # it. Does nothing before `start`.
    def drain : Nil
      io = @io
      return unless io

      reason = read_failure(io)
      fail(reason) if reason
    end

    # Opens a kernel event socket filtered to Apple's data link events.
    private def open_kernel_events : IO::FileDescriptor
      fd = LibC.socket(Device::LibUtun::PF_SYSTEM, LibC::SOCK_RAW, LibKernelEvent::SYSPROTO_EVENT)
      raise IO::Error.from_errno("socket(PF_SYSTEM, SYSPROTO_EVENT)") if fd < 0

      filter = LibKernelEvent::KevRequest.new(vendor_code: LibKernelEvent::KEV_VENDOR_APPLE,
        kev_class: LibKernelEvent::KEV_NETWORK_CLASS, kev_subclass: LibKernelEvent::KEV_DL_SUBCLASS)
      if Device::LibUtun.ioctl(fd, LibKernelEvent::SIOCSKEVFILT, pointerof(filter)) < 0
        error = IO::Error.from_errno("ioctl(SIOCSKEVFILT)")
        LibC.close(fd)
        raise error
      end

      io = IO::FileDescriptor.new(fd)
      io.close_on_exec = true
      # One read is one event; a buffer would join them.
      io.read_buffering = false
      io
    end

    # Stops the watcher without calling *on_failure*; it may be called more
    # than once.
    def close : Nil
      @closing = true
      @io.try(&.close)
    end

    # Waits for the source to become readable without holding the mutex,
    # so `drain` is never kept waiting for an event, then reads what is
    # buffered. `close` wakes the wait, and the read then sees the closed
    # source.
    private def watch(io : IO::FileDescriptor) : Nil
      loop do
        reason = wait_failure(io) || read_failure(io)
        next unless reason

        fail(reason)
        return
      end
    end

    # Waits until *io* is readable; the reason when the wait raised, else
    # nil. Only the reason is rescued, so an exception that `fail` raises
    # (from *on_failure* or the log) is not caught and reported again.
    private def wait_failure(io : IO::FileDescriptor) : String?
      Crystal::EventLoop.current.wait_readable(io)
      nil
    rescue ex
      failure_reason(ex)
    end

    # Reads the buffered events under `@reading`; the reason the source
    # failed, or nil while it is open. As in `wait_failure`, `fail` runs
    # outside the rescue.
    private def read_failure(io : IO::FileDescriptor) : String?
      open = @reading.synchronize { read_available(io) }
      open ? nil : "kernel event socket closed"
    rescue ex
      failure_reason(ex)
    end

    private def failure_reason(exception : Exception) : String
      "#{exception.class}: #{exception.message}"
    end

    # Reads and handles events until the source has none buffered; false
    # when the source has ended. One read is one event. Raises `IO::Error`
    # when *io* is closed or a read fails. Call it holding `@reading`.
    private def read_available(io : IO::FileDescriptor) : Bool
      buffer = Bytes.new(BUFFER_SIZE)
      loop do
        raise IO::Error.new("Closed stream", target: io) if io.closed?

        count = LibC.read(io.fd, buffer, buffer.size)
        if count < 0
          case Errno.value
          when Errno::EINTR
            next
          when Errno::EAGAIN
            return true
          else
            raise IO::Error.from_errno("read", target: io)
          end
        end
        return false if count == 0

        handle(buffer[0, count])
      end
    end

    # Removes the device that *message* names as departed, if registered.
    private def handle(message : Bytes) : Nil
      name = self.class.parse(message)
      return unless name

      @log.info { "departure name=#{name} removed" } if @registry.remove(name)
    end

    # Reports the first failure only: the watcher's fiber and `drain` can
    # both see the same end of the source.
    private def fail(reason : String) : Nil
      return if @closing || @failed

      @failed = true

      @log.error { "departure watcher stopped: #{reason}" }
      @on_failure.try &.call(reason)
    end
  end
end
