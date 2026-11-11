{% skip_file unless flag?(:darwin) %}

class Tunnelgeist::Client
  class Error < IO::Error
    # Why a `Client` call failed.
    enum Reason
      # The socket is missing or nothing listens on it (ENOENT or
      # ECONNREFUSED): the daemon is not running or not installed.
      DaemonUnavailable
      # The caller may not connect to the socket (EACCES).
      ConnectionRefused
      # Any other failure to connect, or an I/O error on the connection.
      ConnectionFailed
      # The daemon did not answer within `Client#timeout`.
      Timeout
      # The reply is not valid, is too long or is cut short.
      InvalidReply
      # The daemon answered with an error reply; the message is its text.
      Refused
      # An ok create reply that carries no name or descriptor.
      NoDevice
    end
  end
end
