require "../../spec_helper"
require "../../../src/tunnelgeist/config/acl_entry"
require "../../../src/tunnelgeist/config/acl_permissions"
require "../../../src/tunnelgeist/config/file_status"
require "../../../src/tunnelgeist/config/trust_policy"

# The rules a configuration file and the directories above it must pass
# (RF5.1, RF5.3), against statuses and ACL entries built by hand.
describe Tunnelgeist::Config::TrustPolicy do
  {% if flag?(:darwin) %}
    alias Config = Tunnelgeist::Config
    alias TrustPolicy = Tunnelgeist::Config::TrustPolicy
    alias Permissions = Tunnelgeist::Config::AclPermissions

    # The trusted user besides root.
    OWNER = 501_u32

    def status(*, type : File::Type = File::Type::File, owner : UInt32 = OWNER, mode : Int32 = 0o644,
               size : Int64 = 10_i64) : Config::FileStatus
      Config::FileStatus.new(type: type, owner: owner, mode: mode.to_u16, size: size)
    end

    def directory(*, owner : UInt32 = 0_u32, mode : Int32 = 0o755) : Config::FileStatus
      status(type: File::Type::Directory, owner: owner, mode: mode)
    end

    def allow(permissions : Permissions, *, uid : UInt32? = nil) : Config::AclEntry
      Config::AclEntry.new(allow: true, uid: uid, permissions: permissions)
    end

    test "directory_problem accepts a directory root or the owner owns that no one else may write" do
      [0o755, 0o700, 0o1755, 0o4755].each do |mode|
        assert(TrustPolicy.directory_problem(directory(mode: mode), owner: OWNER).nil?)
        assert(TrustPolicy.directory_problem(directory(owner: OWNER, mode: mode), owner: OWNER).nil?)
      end
    end

    test "directory_problem refuses anything but a directory" do
      [File::Type::File, File::Type::Symlink, File::Type::Pipe].each do |type|
        assert(TrustPolicy.directory_problem(status(type: type, owner: 0_u32), owner: OWNER) == "must be a directory")
      end
    end

    test "directory_problem refuses a directory of another owner, naming root alone when the owner is root" do
      assert(TrustPolicy.directory_problem(directory(owner: 502_u32), owner: OWNER) ==
             "directory must be owned by root or uid 501, not uid 502")
      assert(TrustPolicy.directory_problem(directory(owner: 501_u32), owner: 0_u32) ==
             "directory must be owned by root, not uid 501")
    end

    test "directory_problem refuses a directory the group or others may write, sticky or not" do
      {0o775 => "0775", 0o757 => "0757", 0o777 => "0777", 0o1777 => "1777"}.each do |mode, text|
        assert(TrustPolicy.directory_problem(directory(mode: mode), owner: OWNER) ==
               "directory must be writable only by its owner, not mode #{text}")
      end
    end

    test "file_problem accepts a regular file of the owner that no one else may write, up to 1 MiB" do
      [0o644, 0o600, 0o444].each do |mode|
        assert(TrustPolicy.file_problem(status(mode: mode), owner: OWNER).nil?)
      end
      assert(TrustPolicy.file_problem(status(size: 1_048_576_i64), owner: OWNER).nil?)
    end

    test "file_problem refuses anything but a regular file" do
      [File::Type::Directory, File::Type::Pipe, File::Type::CharacterDevice, File::Type::Socket].each do |type|
        assert(TrustPolicy.file_problem(status(type: type), owner: OWNER) == "must be a regular file")
      end
    end

    test "file_problem refuses a file of another owner, root included" do
      [0_u32, 502_u32].each do |owner|
        assert(TrustPolicy.file_problem(status(owner: owner), owner: OWNER) == "must be owned by uid 501, not uid #{owner}")
      end
    end

    test "file_problem refuses a file the group or others may write" do
      [0o664, 0o646, 0o666].each do |mode|
        assert(TrustPolicy.file_problem(status(mode: mode), owner: OWNER) ==
               "must be writable only by its owner, not mode #{"%04o" % mode}")
      end
    end

    test "file_problem refuses a file over 1 MiB" do
      assert(TrustPolicy.file_problem(status(size: 1_048_577_i64), owner: OWNER) == "must be at most 1 MiB (1048576 bytes)")
    end

    test "acl_problem accepts no ACL, denials, and grants to read, list or search" do
      assert(TrustPolicy.acl_problem([] of Config::AclEntry, owner: OWNER).nil?)
      entries = [
        Config::AclEntry.new(allow: false, uid: nil, permissions: Permissions::All),
        allow(Permissions::ReadData | Permissions::Execute | Permissions::ReadAttributes |
              Permissions::ReadExtattributes | Permissions::ReadSecurity | Permissions::Synchronize),
        allow(Permissions::ReadData, uid: 502_u32),
      ]

      assert(TrustPolicy.acl_problem(entries, owner: OWNER).nil?)
    end

    test "acl_problem accepts any grant to the owner" do
      assert(TrustPolicy.acl_problem([allow(Permissions::All, uid: OWNER)], owner: OWNER).nil?)
    end

    test "acl_problem refuses a grant of a generic or unnamed right to another user, a group or an unknown principal" do
      # GENERIC_ALL, GENERIC_EXECUTE, GENERIC_WRITE, GENERIC_READ, a bit
      # between the named ones and one above them.
      [0x200000_u64, 0x400000_u64, 0x800000_u64, 0x1000000_u64, 0x4000_u64, 0x8000_0000_u64].each do |bits|
        [502_u32, 0_u32, nil].each do |uid|
          entries = [allow(Permissions.new(bits) | Permissions::ReadData, uid: uid)]

          assert(TrustPolicy.acl_problem(entries, owner: OWNER) == "grants write access through its ACL")
        end
      end
    end

    test "acl_problem refuses a grant of any write permission to another user, a group or an unknown principal" do
      writes = [Permissions::WriteData, Permissions::AppendData, Permissions::WriteAttributes,
                Permissions::WriteExtattributes, Permissions::WriteSecurity, Permissions::ChangeOwner,
                Permissions::Delete, Permissions::DeleteChild]
      writes.each do |permission|
        [502_u32, 0_u32, nil].each do |uid|
          entries = [allow(Permissions::ReadData, uid: uid), allow(permission | Permissions::ReadData, uid: uid)]

          assert(TrustPolicy.acl_problem(entries, owner: OWNER) == "grants write access through its ACL")
        end
      end
    end
  {% end %}
end
