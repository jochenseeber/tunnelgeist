{% skip_file unless flag?(:darwin) %}

require "system/group"
require "./decimal"
require "./lib_system"
require "./peer"

module Tunnelgeist
  # Membership in the helper's group (UA8), asked of the directory service
  # with `mbr_check_membership`, so supplementary and nested groups count as
  # they do for file access.
  class Membership
    # The gid the group resolved to when the check was built; later renames
    # are not seen.
    getter gid : UInt32
    # The group's name, also when it was given by gid, for messages that name
    # the group.
    getter name : String
    @uuid = LibSystem::UuidT.new(0_u8)

    # Resolves *group*, a group name or a gid written in ASCII digits (group
    # names never are digits only); raises `ArgumentError` when the system
    # does not know it.
    def initialize(group : String)
      found = if Decimal.digits?(group)
                System::Group.find_by?(id: group) || raise ArgumentError.new("unknown group id #{group}")
              else
                System::Group.find_by?(name: group) || raise ArgumentError.new("unknown group #{group}")
              end

      @name = found.name
      @gid = found.id.to_u32
      result = LibSystem.mbr_gid_to_uuid(@gid, pointerof(@uuid).as(UInt8*))
      raise ArgumentError.new("group #{group} has no directory identity (#{Errno.new(result)})") unless result == 0
    end

    # Whether *peer*'s effective uid is a member. Raises `IO::Error` naming
    # the call when the directory service fails, so the caller can tell a
    # failure from a non-member.
    def member?(peer : Peer) : Bool
      user = LibSystem::UuidT.new(0_u8)
      result = LibSystem.mbr_uid_to_uuid(peer.uid, user.to_unsafe)
      raise IO::Error.new("mbr_uid_to_uuid(#{peer.uid}): #{Errno.new(result).message}") unless result == 0

      is_member = 0
      result = LibSystem.mbr_check_membership(user.to_unsafe, pointerof(@uuid).as(UInt8*), pointerof(is_member))
      raise IO::Error.new("mbr_check_membership: #{Errno.new(result).message}") unless result == 0

      is_member == 1
    end
  end
end
