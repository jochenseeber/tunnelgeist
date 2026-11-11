{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  class Install
    # The owner and group `install` gives the files it writes, and the
    # owner it requires of the directories they go into.
    record Owner, uid : UInt32, gid : UInt32 do
      # root:wheel, the owner of a real installation (UC3).
      def self.root : Owner
        new(uid: 0_u32, gid: 0_u32)
      end
    end
  end
end
