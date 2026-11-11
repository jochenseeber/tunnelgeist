{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  class Install
    # The owner and group `install` gives the files and directories it
    # creates, and the owner besides root it allows for every directory
    # from `/` down to them.
    record Owner, uid : UInt32, gid : UInt32 do
      # root:wheel, the owner of a real installation (UC3).
      def self.root : Owner
        new(uid: 0_u32, gid: 0_u32)
      end
    end
  end
end
