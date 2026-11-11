{% skip_file unless flag?(:darwin) %}

require "socket"
require "./lib_bsm"
require "./lib_system"

module Tunnelgeist
  # A connected client as its audit token names it (UA8): the effective uid
  # and gid, the pid, and the token itself, which also carries the pid
  # version, so the signature check (UA11) reaches this process and not a
  # later one that reuses its pid.
  record Peer, uid : UInt32, gid : UInt32, pid : Int32, token : LibSystem::AuditToken do
    # Reads the audit token of the process at the other end of *socket*,
    # with one `getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN)`. Raises `IO::Error`
    # when the socket is closed or the kernel refuses.
    def self.of(socket : UNIXSocket) : Peer
      raise IO::Error.new("Closed stream") if socket.closed?

      token = LibSystem::AuditToken.new
      size = LibC::SocklenT.new(sizeof(LibSystem::AuditToken))
      result = LibC.getsockopt(socket.fd, LibSystem::SOL_LOCAL, LibSystem::LOCAL_PEERTOKEN, pointerof(token).as(Void*),
        pointerof(size))
      raise IO::Error.from_errno("getsockopt(LOCAL_PEERTOKEN)") unless result == 0
      unless size == sizeof(LibSystem::AuditToken)
        raise IO::Error.new("getsockopt(LOCAL_PEERTOKEN) returned #{size} bytes, not #{sizeof(LibSystem::AuditToken)}")
      end

      new(uid: LibBSM.audit_token_to_euid(token), gid: LibBSM.audit_token_to_egid(token),
        pid: LibBSM.audit_token_to_pid(token), token: token)
    end
  end
end
