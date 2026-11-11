{% skip_file unless flag?(:darwin) %}

require "socket"

module Tunnelgeist
  module CLI
    # The path of the socket `serve` listens on: made free before `serve`
    # binds it when launchd did not start the daemon, and read back from a
    # socket launchd passed.
    module SocketPath
      # Makes way for a socket at *path*: nothing to do when nothing is
      # there, deletes a socket file nothing listens on, and raises
      # `File::AlreadyExistsError` naming *path* for a socket something
      # listens on, so a second `serve` never takes the path of a running
      # daemon, and for any other file.
      #
      # A refused connect is what shows a socket stale. On macOS a listener
      # whose backlog is full refuses a connect with `ECONNREFUSED` too, so
      # the socket of a daemon too busy to accept is taken for stale and
      # removed; that is the accepted limit of this check.
      def self.clear(path : String) : Nil
        info = File.info?(path, follow_symlinks: false)
        return unless info
        raise File::AlreadyExistsError.new("#{path} exists and is not a socket", file: path) unless info.type.socket?

        remove_stale(path)
      end

      # The path *server* is bound to, as the kernel reports it.
      # `UNIXServer#local_address` only repeats the path the object was
      # made with, which is empty for a descriptor launchd passed. Raises
      # `Socket::Error` when the kernel cannot say, and when the socket has
      # no path, being unbound or unnamed, since no client could reach it.
      def self.bound(server : UNIXServer) : String
        address = uninitialized LibC::SockaddrUn
        length = LibC::SocklenT.new(sizeof(LibC::SockaddrUn))
        sockaddr = pointerof(address).as(LibC::Sockaddr*)
        raise Socket::Error.from_errno("getsockname") unless LibC.getsockname(server.fd, sockaddr, pointerof(length)) == 0

        path = Socket::UNIXAddress.from(sockaddr, length).path
        raise Socket::Error.new("listening socket has no path") if path.empty?

        path
      end

      # Deletes the socket file at *path* when nothing listens on it, which a
      # refused connect shows; raises `Socket::ConnectError` naming *path*
      # with the error of the connect for any other failure.
      private def self.remove_stale(path : String) : Nil
        UNIXSocket.new(path).close
      rescue ex : Socket::ConnectError
        case ex.os_error
        when Errno::ECONNREFUSED
          File.delete(path)
        when Errno::ENOENT
          # Removed since `clear` looked; nothing is left to delete.
        else
          raise Socket::ConnectError.from_os_error("connect", ex.os_error, target: path)
        end
      else
        raise File::AlreadyExistsError.new("#{path} is a socket something listens on", file: path)
      end
    end
  end
end
