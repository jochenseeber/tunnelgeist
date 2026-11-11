{% skip_file unless flag?(:darwin) %}

require "socket"
require "./launchd/lib_launch"

module Tunnelgeist
  # launchd socket activation (UA5, UA9): the daemon takes its listening
  # socket from the `Sockets` entry of its LaunchDaemon property list.
  module Launchd
    # The `Sockets` key of the property list `install` writes.
    SOCKET_NAME = "Listeners"

    # The descriptors launchd opened for the socket entry *name*, or nil
    # when launchd did not start this process (`ESRCH`). Raises `IO::Error`
    # for any other failure, such as an entry the job does not have.
    private def self.activate_socket(name : String) : Array(Int32)?
      fds = Pointer(LibC::Int).null
      count = LibC::SizeT.new(0)
      result = LibLaunch.launch_activate_socket(name, pointerof(fds), pointerof(count))
      return if result == Errno::ESRCH.value
      raise IO::Error.new("launch_activate_socket(#{name}): #{Errno.new(result).message}") unless result == 0

      begin
        Array.new(count.to_i) { |index| fds[index].to_i32 }
      ensure
        LibC.free(fds.as(Void*)) unless fds.null?
      end
    end

    # The listening socket of the entry `SOCKET_NAME`, or nil when launchd
    # did not start this process, as when `serve` runs from a shell, so the
    # caller binds a socket itself (CA6). Raises `IO::Error` when launchd
    # started it but the socket cannot be had: an error other than `ESRCH`,
    # or a descriptor count other than one, whose descriptors are closed.
    def self.listener : UNIXServer?
      fds = activate_socket(SOCKET_NAME)
      return unless fds

      unless fds.size == 1
        fds.each { |descriptor| LibC.close(descriptor) }
        raise IO::Error.new("launchd passed #{fds.size} sockets for #{SOCKET_NAME}, expected 1")
      end

      server = UNIXServer.new(fd: fds.first)
      server.close_on_exec = true
      server
    end
  end
end
