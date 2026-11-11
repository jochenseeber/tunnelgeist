require "../test_helper"
require "../../src/tunnelgeist/signature_policy"
require "../../src/tunnelgeist/signature_policy/inspection"
require "./support/own_peer"

# The signature check of UA11 on this process, as Security reads it: the
# spec binary is ad-hoc signed, without the hardened runtime.
describe TunnelgeistSignaturePolicy do
  {% if flag?(:darwin) %}
    alias LibSecurity = Tunnelgeist::LibSecurity

    include TunnelgeistOwnPeer

    # The result of *policy* for *peer*, read with an inspection of its own.
    def checked(policy : Tunnelgeist::SignaturePolicy, *, peer : Tunnelgeist::Peer) : Tunnelgeist::Refusal?
      inspection = Tunnelgeist::SignaturePolicy::Inspection.of(peer)
      begin
        policy.check(inspection)
      ensure
        inspection.close
      end
    end

    test "a policy without requirements passes this process" do
      policy = Tunnelgeist::SignaturePolicy.new([] of String)

      with_own_peer { |peer| assert(checked(policy, peer: peer).nil?) }
    end

    test "check refuses this ad-hoc signed process for a requirement it does not meet (UT2a)" do
      policy = Tunnelgeist::SignaturePolicy.new(["anchor apple generic"])

      assert(!policy.empty?)
      with_own_peer { |peer| assert(checked(policy, peer: peer).to_s == "requirement") }
    end

    test "check reads the status of this process when it meets a requirement" do
      policy = Tunnelgeist::SignaturePolicy.new(["anchor apple generic", "always"])

      with_own_peer { |peer| assert(checked(policy, peer: peer).to_s == "hardened runtime") }
    end

    test "Inspection.of finds this process and reads its signing information" do
      with_own_peer do |peer|
        inspection = Tunnelgeist::SignaturePolicy::Inspection.of(peer)
        begin
          assert(inspection.found?)
          flags = inspection.signing_flags

          assert(!flags.nil?)
          assert(inspection.signing_flags!.status.bits_set?(LibSecurity::CS_VALID))
        ensure
          inspection.close
        end
      end
    end

    test "Inspection can be closed twice and refuses to be used after close" do
      with_own_peer do |peer|
        inspection = Tunnelgeist::SignaturePolicy::Inspection.of(peer)

        assert(!inspection.closed?)
        inspection.close
        inspection.close

        assert(inspection.closed?)
        error = raised(IO::Error) { Tunnelgeist::SignaturePolicy.new(["always"]).check(inspection) }
        assert(error.message == "Closed inspection")
      end
    end

    test "one inspection shared by policies gives each the result an inspection of its own gives" do
      policies = [
        Tunnelgeist::SignaturePolicy.new([] of String),
        Tunnelgeist::SignaturePolicy.new(["anchor apple generic"]),
        Tunnelgeist::SignaturePolicy.new(["anchor apple generic", "always"]),
      ]

      with_own_peer do |peer|
        inspection = Tunnelgeist::SignaturePolicy::Inspection.of(peer)
        begin
          results = policies.map(&.check(inspection))

          assert(results.map(&.to_s) == ["", "requirement", "hardened runtime"])
          assert(results == policies.map { |policy| checked(policy, peer: peer) })
        ensure
          inspection.close
        end
      end
    end
  {% end %}
end
