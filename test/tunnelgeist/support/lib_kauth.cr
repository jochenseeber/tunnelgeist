require "c/sys/types"

# The raw system call that sets a file's ACL from a `struct kauth_filesec`
# (sys/kauth.h), which takes rights `acl_set_permset_mask_np` refuses, such
# as the generic ones. libSystem exports no wrapper for it, so it goes
# through `syscall`. Values from the macOS SDK headers.
lib TunnelgeistLibKauth
  # `fsec_magic` of a `struct kauth_filesec`.
  KAUTH_FILESEC_MAGIC = 0x012cc16d_u32
  # A uid or gid that leaves the owner or group as it is: `~0 - 100`.
  KAUTH_UID_NONE = 4_294_967_195_u32
  # The kind of an entry that allows (`ace_flags`).
  KAUTH_ACE_PERMIT = 1_u32

  # `struct kauth_ace`.
  struct KauthAce
    ace_applicable : StaticArray(UInt8, 16)
    ace_flags : UInt32
    ace_rights : UInt32
  end

  # `struct kauth_filesec` with an ACL of one entry.
  struct KauthFilesec
    fsec_magic : UInt32
    fsec_owner : StaticArray(UInt8, 16)
    fsec_group : StaticArray(UInt8, 16)
    acl_entrycount : UInt32
    acl_flags : UInt32
    acl_ace : KauthAce
  end

  # `fchmod_extended(fd, uid, gid, mode, xsecurity)`: sets the owner,
  # group, mode (-1 keeps it) and ACL of the open file *fd* (sys/syscall.h).
  SYS_FCHMOD_EXTENDED = 283

  # Runs the system call *number* with the arguments that follow (unistd.h).
  fun syscall(number : ::LibC::Int, ...) : ::LibC::Int
end
