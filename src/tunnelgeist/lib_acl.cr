{% skip_file unless flag?(:darwin) %}

require "c/sys/types"

module Tunnelgeist
  # The extended ACL functions `TrustedDirectory` reads an open
  # file's access control list with (sys/acl.h, in libSystem). Values from
  # the macOS SDK headers (`xcrun --show-sdk-path`, then
  # `usr/include/sys/acl.h`).
  lib LibAcl
    # `acl_type_t`: the one ACL type macOS supports.
    ACL_TYPE_EXTENDED = 0x00000100
    # `acl_entry_id_t`: the first entry, and the one after the last read.
    ACL_FIRST_ENTRY =  0
    ACL_NEXT_ENTRY  = -1
    # `acl_tag_t`: an entry that grants its permissions.
    ACL_EXTENDED_ALLOW = 1

    # `acl_t` and `acl_entry_t`: opaque pointers.
    alias AclT = Void*
    alias AclEntryT = Void*

    # The ACL of the open file *fd*; null with `errno` `ENOENT` when it has
    # none.
    fun acl_get_fd_np(fd : ::LibC::Int, type : ::LibC::Int) : AclT
    # The entry *entry_id* of *acl* in *entry_p*; -1 with `errno` `EINVAL`
    # after the last.
    fun acl_get_entry(acl : AclT, entry_id : ::LibC::Int, entry_p : AclEntryT*) : ::LibC::Int
    fun acl_get_tag_type(entry : AclEntryT, tag_type_p : ::LibC::Int*) : ::LibC::Int
    # The `guid_t` of the user or group the entry is about, which the
    # caller frees with `acl_free`.
    fun acl_get_qualifier(entry : AclEntryT) : Void*
    # The entry's permissions as the bits of `acl_perm_t`.
    fun acl_get_permset_mask_np(entry : AclEntryT, mask_p : UInt64*) : ::LibC::Int
    fun acl_free(obj_p : Void*) : ::LibC::Int
  end
end
