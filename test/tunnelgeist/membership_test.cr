require "../test_helper"
require "../../src/tunnelgeist/membership"
require "./support/own_peer"

# Membership of a peer in the helper's group (UA8), asked of the system's
# directory service with this process as the peer: every macOS user is in
# `staff`, nobody in `nogroup`.
describe TunnelgeistMembership do
  {% if flag?(:darwin) %}
    include TunnelgeistOwnPeer

    test "Membership resolves the group's gid" do
      staff = System::Group.find_by(name: "staff").id.to_u32

      assert(Tunnelgeist::Membership.new("staff").gid == staff)
    end

    test "Membership.member? is true for a user whose primary group it is" do
      with_own_peer do |peer|
        assert(Tunnelgeist::Membership.new("staff").member?(peer))
      end
    end

    test "Membership.member? is false for a group the user is not in" do
      with_own_peer do |peer|
        assert(!Tunnelgeist::Membership.new("nogroup").member?(peer))
      end
    end

    test "Membership resolves a group given by name or by gid to its name and gid" do
      staff = System::Group.find_by(name: "staff")

      by_name = Tunnelgeist::Membership.new("staff")
      by_gid = Tunnelgeist::Membership.new(staff.id)

      assert(by_name.name == "staff")
      assert(by_gid.name == "staff")
      assert(by_gid.gid == staff.id.to_u32)
    end

    test "Membership.new raises ArgumentError naming an unknown gid" do
      error = raised(ArgumentError) { Tunnelgeist::Membership.new("4294967") }

      assert(error.message == "unknown group id 4294967")
    end

    test "Membership takes a gid with leading zeros as a gid" do
      staff = System::Group.find_by(name: "staff")

      assert(Tunnelgeist::Membership.new("00#{staff.id}").name == "staff")
    end

    test "Membership looks up a group by name unless it is all ASCII digits" do
      staff = System::Group.find_by(name: "staff")

      ["#{staff.id}\n", "+#{staff.id}", " #{staff.id}", "٢٠", "２０", ""].each do |group|
        error = raised(ArgumentError) { Tunnelgeist::Membership.new(group) }

        assert(error.message == "unknown group #{group}")
      end
    end

    test "Membership.new raises ArgumentError naming an unknown group" do
      error = raised(ArgumentError) { Tunnelgeist::Membership.new("no-such-group-xyz") }

      assert(error.message == "unknown group no-such-group-xyz")
    end
  {% end %}
end
