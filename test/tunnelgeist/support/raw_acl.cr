require "c/fcntl"
require "c/unistd"
require "../../../src/tunnelgeist/lib_system"
require "./lib_kauth"

# Sets ACLs `chmod +a` cannot, such as an entry with a generic right, which
# `ls -le` shows as an `allow` with no rights after it.
module TunnelgeistRawAcl
  extend self

  # The gid of the group `everyone`.
  EVERYONE_GID = 12_u32

  # Replaces the ACL of *path* with one entry that allows the group
  # `everyone` the raw `acl_perm_t` bits *rights*.
  def allow_everyone(path : String, *, rights : UInt32) : Nil
    everyone = StaticArray(UInt8, 16).new(0_u8)
    raise "mbr_gid_to_uuid failed" unless Tunnelgeist::LibSystem.mbr_gid_to_uuid(EVERYONE_GID, everyone.to_unsafe) == 0

    ace = TunnelgeistLibKauth::KauthAce.new
    ace.ace_applicable = everyone
    ace.ace_flags = TunnelgeistLibKauth::KAUTH_ACE_PERMIT
    ace.ace_rights = rights
    filesec = TunnelgeistLibKauth::KauthFilesec.new
    filesec.fsec_magic = TunnelgeistLibKauth::KAUTH_FILESEC_MAGIC
    filesec.acl_entrycount = 1_u32
    filesec.acl_ace = ace

    # A directory opens read-only as well as a file does.
    fd = LibC.open(path, LibC::O_RDONLY | LibC::O_CLOEXEC)
    raise RuntimeError.from_errno("open #{path}") if fd < 0
    begin
      result = TunnelgeistLibKauth.syscall(TunnelgeistLibKauth::SYS_FCHMOD_EXTENDED, fd,
        TunnelgeistLibKauth::KAUTH_UID_NONE, TunnelgeistLibKauth::KAUTH_UID_NONE, -1, pointerof(filesec))
      raise RuntimeError.from_errno("fchmod_extended #{path}") unless result == 0
    ensure
      LibC.close(fd)
    end
  end
end
