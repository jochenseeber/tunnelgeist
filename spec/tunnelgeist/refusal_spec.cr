require "../spec_helper"
require "../../src/tunnelgeist/refusal"

# The check names a refusal writes after `check=` in the log.
describe TunnelgeistRefusal do
  {% if flag?(:darwin) %}
    alias Reason = Tunnelgeist::Refusal::Reason

    test "to_s writes the check name of every reason without an entitlement" do
      names = {
        Reason::Group                  => "group",
        Reason::Requirement            => "requirement",
        Reason::Debugged               => "debugged",
        Reason::Debuggable             => "debuggable",
        Reason::HardenedRuntime        => "hardened runtime",
        Reason::EntitlementsUnreadable => "entitlements unreadable",
        Reason::Users                  => "users",
        Reason::Groups                 => "groups",
        Reason::Config                 => "config",
      }

      names.each do |reason, name|
        assert(Tunnelgeist::Refusal.new(reason: reason).to_s == name)
      end
    end

    test "to_s names the entitlement of an entitlement refusal" do
      refusal = Tunnelgeist::Refusal.entitlement(Tunnelgeist::Entitlement::GetTaskAllow)

      assert(refusal.to_s == "entitlement com.apple.security.get-task-allow")
    end
  {% end %}
end
