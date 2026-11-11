{% skip_file unless flag?(:darwin) %}

require "c/sys/types"

module Tunnelgeist
  # The macOS declarations the helper's peer check (UA8) and its socket setup
  # need and the standard library's `LibC` lacks. Values from the macOS SDK
  # headers (`xcrun --show-sdk-path`, then `usr/include/...`), checked against a
  # C program built with that SDK: `SOL_LOCAL` is 0, `LOCAL_PEERTOKEN` 6,
  # `audit_token_t` 32 bytes and `uuid_t` 16.
  lib LibSystem
    # The option level of local (Unix domain) sockets (sys/un.h).
    SOL_LOCAL = 0
    # The socket option that reads the peer's audit token (sys/un.h).
    LOCAL_PEERTOKEN = 6

    # `audit_token_t` (mach/message.h): eight words that name a process,
    # including its pid version.
    struct AuditToken
      val : StaticArray(UInt32, 8)
    end

    # `uuid_t` (uuid/uuid.h).
    alias UuidT = StaticArray(UInt8, 16)

    # The effective uid and gid of the calling process (unistd.h).
    fun geteuid : ::LibC::UidT
    fun getegid : ::LibC::GidT

    # Directory-service identities and group membership (membership.h); each
    # returns 0 or an errno value.
    fun mbr_uid_to_uuid(uid : ::LibC::UidT, uu : UInt8*) : ::LibC::Int
    fun mbr_gid_to_uuid(gid : ::LibC::GidT, uu : UInt8*) : ::LibC::Int
    fun mbr_check_membership(user : UInt8*, group : UInt8*, ismember : ::LibC::Int*) : ::LibC::Int

    # Sets the mode of *path* without following a symbolic link there
    # (sys/stat.h).
    fun lchmod(path : ::LibC::Char*, mode : ::LibC::ModeT) : ::LibC::Int
  end
end
