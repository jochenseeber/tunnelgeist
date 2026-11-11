{% skip_file unless flag?(:darwin) %}

require "./acl_permissions"

module Tunnelgeist
  # One entry of a file's extended ACL, as far as `TrustPolicy` judges it:
  # whether it allows or denies, the uid it is about (nil for a group or a
  # principal the directory service cannot name as a user), and its
  # permissions.
  record AclEntry, allow : Bool, uid : UInt32?, permissions : AclPermissions do
    # The uid the entry is about; raises `NilAssertionError` for a group
    # or an unknown principal.
    def uid! : UInt32
      @uid || raise NilAssertionError.new("the ACL entry names no user")
    end
  end
end
