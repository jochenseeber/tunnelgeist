{% skip_file unless flag?(:darwin) %}

require "json"
require "log"
require "socket"
require "./prefix"
require "./address"
require "./fd_passing"
require "./interface_name"
require "./key"
require "./protocol"
require "./client/device"
require "./client/error"
require "./client/exchange"
require "./client/handle"
require "./client/reply_line"

module Tunnelgeist
  # The client of the root daemon `tunnelgeist` (TA2). An unprivileged
  # program asks it for a utun device, receives the descriptor over the
  # Unix socket and later adds or removes addresses and routes with the
  # key of the device. The client does not wrap the descriptor: it
  # belongs to the caller.
  #
  # Every call opens its own connection and exchanges one request line
  # and one reply line. This file does not require anything of the
  # daemon, so a program that links the library does not link `Security`.
  class Client
    # The socket the daemon listens on unless told otherwise.
    DEFAULT_SOCKET = Protocol::DEFAULT_SOCKET
    # The default for `timeout`.
    DEFAULT_TIMEOUT = 10.seconds
    # The most bytes of one reply line the client reads.
    REPLY_BUFFER_SIZE = Protocol::MAX_REPLY
    # Library log; the program that links the client configures `Log`.
    LOG = ::Log.for("tunnelgeist.client")

    # How long the connect and the whole exchange may take.
    property timeout : Time::Span = DEFAULT_TIMEOUT

    # The socket `connect` opens; `Protocol::DEFAULT_SOCKET` unless given to
    # `new`.
    getter socket_path : String

    # Nothing is opened here: every call connects on its own, so a client can
    # outlive a daemon restart.
    def initialize(@socket_path : String = Protocol::DEFAULT_SOCKET)
    end

    # Asks the daemon for a device named *name* (any free one when nil)
    # and returns it with its descriptor. Raises `Error` when the daemon is
    # not reachable, refuses or does not answer, or sends no device.
    def create(name : InterfaceName? = nil, *, mtu : Int32 = Protocol::DEFAULT_MTU, addresses : Array(Address) = [] of Address,
               routes : Array(Prefix) = [] of Prefix) : Device
      request = Protocol::Create.new(name: name, mtu: mtu, addresses: addresses, routes: routes)
      exchange = exchange_with_descriptor(request)
      reply = exchange.reply
      fd = exchange.fd

      device_name = reply.name
      key = reply.key
      unless device_name && key && fd
        LibC.close(fd) if fd
        raise Error.new("tunnelgeist returned no device", reason: Error::Reason::NoDevice)
      end

      Device.new(self, name: device_name, key: key, mtu: mtu, fd: fd)
    end

    # The handle of the device *name* made earlier, with its *key*. No check
    # that the device exists until the first call.
    def handle(name : InterfaceName, *, key : Key) : Handle
      Handle.new(self, name: name, key: key)
    end

    protected def exchange(request : Protocol::Request) : Nil
      fd = exchange_with_descriptor(request).fd
      LibC.close(fd) if fd
    end

    # Sends *request* and returns the ok reply and the descriptor that came
    # with it, if any, as an `Exchange`. Every failure raises `Error`, closing
    # a descriptor that arrived: an error reply, a timeout, and any
    # `IO::Error` of the connection, such as `EPIPE` when the daemon closes
    # before the request is written or a failed `recvmsg`.
    private def exchange_with_descriptor(request : Protocol::Request) : Exchange
      deadline = Time.instant + @timeout
      socket = connect
      begin
        write_request(socket, request: request, deadline: deadline)
        checked_reply(read_reply(socket, deadline: deadline))
      rescue error : IO::TimeoutError
        raise Error.new(timeout_message, reason: Error::Reason::Timeout, cause: error)
      ensure
        close_connection(socket)
      end
    rescue error : Error
      raise error
    rescue error : IO::Error
      raise Error.new("tunnelgeist connection failed: #{error.message}", reason: Error::Reason::ConnectionFailed, cause: error)
    end

    # Writes *request* as one line, within the time left until *deadline*.
    private def write_request(socket : UNIXSocket, *, request : Protocol::Request, deadline : Time::Instant) : Nil
      socket.write_timeout = time_left(deadline)
      socket.write("#{request.to_json}\n".to_slice)
      socket.flush
    end

    # The reply in *received* with its descriptor as an `Exchange` when it
    # is a valid ok reply. Raises `Error` otherwise, closing the
    # descriptor.
    private def checked_reply(received : ReplyLine) : Exchange
      fd = received.fd
      reply = begin
        Protocol::Reply.parse(received.line)
      rescue error : Protocol::Error
        LibC.close(fd) if fd
        raise Error.new("tunnelgeist sent an invalid reply: #{error.message}", reason: Error::Reason::InvalidReply, cause: error)
      end

      unless reply.ok
        LibC.close(fd) if fd
        raise Error.new(reply.error || "tunnelgeist refused the request", reason: Error::Reason::Refused)
      end

      Exchange.new(reply: reply, fd: fd)
    end

    # Closes *socket*. A failed close is only logged, so that it does not
    # lose a descriptor that already arrived.
    private def close_connection(socket : UNIXSocket) : Nil
      socket.close
    rescue error : IO::Error
      LOG.debug(exception: error) { "closing the connection failed" }
    end

    # The time left until *deadline*, so that every step of one exchange
    # shares the one deadline; raises `IO::TimeoutError` when it has passed.
    private def time_left(deadline : Time::Instant) : Time::Span
      remaining = deadline - Time.instant
      raise IO::TimeoutError.new("exchange deadline") unless remaining.positive?

      remaining
    end

    private def timeout_message : String
      "tunnelgeist did not answer within #{@timeout.total_seconds.to_s.chomp(".0")} seconds"
    end

    private def connect : UNIXSocket
      UNIXSocket.new(@socket_path)
    rescue error : ArgumentError
      # A socket path longer than `sockaddr_un` holds.
      raise Error.new("tunnelgeist connection failed: #{error.message}", reason: Error::Reason::ConnectionFailed, cause: error)
    rescue error : Socket::ConnectError | File::Error
      case error.os_error
      when Errno::ENOENT, Errno::ECONNREFUSED
        raise Error.new("tunnelgeist is not running or not installed (#{@socket_path})", reason: Error::Reason::DaemonUnavailable, cause: error)
      when Errno::EACCES
        raise Error.new("tunnelgeist refused the connection (#{@socket_path}): not permitted", reason: Error::Reason::ConnectionRefused, cause: error)
      else
        raise Error.new("tunnelgeist connection failed: #{error.message}", reason: Error::Reason::ConnectionFailed, cause: error)
      end
    end

    # The first line of the reply and the descriptor on its first
    # segment, as a `ReplyLine`. Reads until the newline, within the *deadline*.
    private def read_reply(socket : UNIXSocket, *, deadline : Time::Instant) : ReplyLine
      buffer = Bytes.new(REPLY_BUFFER_SIZE)
      socket.read_timeout = time_left(deadline)
      received = FdPassing.receive(socket, buffer: buffer)
      count = received.size
      fd = received.fd
      used = count

      newline = nil
      begin
        loop do
          newline = buffer[0, used].index('\n'.ord.to_u8)
          break if newline

          raise Error.new("tunnelgeist closed the connection without a complete reply", reason: Error::Reason::InvalidReply) if count == 0
          raise Error.new("tunnelgeist sent a reply longer than #{REPLY_BUFFER_SIZE} bytes", reason: Error::Reason::InvalidReply) if used == buffer.size

          socket.read_timeout = time_left(deadline)
          count = socket.read(buffer[used, buffer.size - used])
          used += count
        end
      rescue error
        LibC.close(fd) if fd
        raise error
      end

      ReplyLine.new(line: String.new(buffer[0, newline || used]), fd: fd)
    end
  end
end
