{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  # The permissions of an extended ACL entry, the bits of `acl_perm_t`
  # (sys/acl.h) and the generic rights of `struct kauth_ace`
  # (sys/kauth.h), which the kernel expands into the others when it
  # checks access. On a directory the same bits mean other things:
  # `WriteData` is `add_file`, `AppendData` `add_subdirectory`, `ReadData`
  # `list` and `Execute` `search`.
  @[Flags]
  enum AclPermissions : UInt64
    ReadData           =       0x2
    WriteData          =       0x4
    Execute            =       0x8
    Delete             =      0x10
    AppendData         =      0x20
    DeleteChild        =      0x40
    ReadAttributes     =      0x80
    WriteAttributes    =     0x100
    ReadExtattributes  =     0x200
    WriteExtattributes =     0x400
    ReadSecurity       =     0x800
    WriteSecurity      =    0x1000
    ChangeOwner        =    0x2000
    Synchronize        =  0x100000
    GenericAll         =  0x200000
    GenericExecute     =  0x400000
    GenericWrite       =  0x800000
    GenericRead        = 0x1000000
  end
end
