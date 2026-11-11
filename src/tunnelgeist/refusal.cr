{% skip_file unless flag?(:darwin) %}

require "./entitlement"
require "./refusal/reason"

module Tunnelgeist
  # The failed check of a peer the daemon refused. Its text is what the log
  # shows after `check=`.
  record Refusal, reason : Reason, entitlement : Entitlement? = nil do
    # The refusal for holding *entitlement*.
    def self.entitlement(entitlement : Entitlement) : Refusal
      new(reason: Reason::Entitlement, entitlement: entitlement)
    end

    # The entitlement of an entitlement refusal; raises when there is none.
    def entitlement! : Entitlement
      entitlement || raise NilAssertionError.new("#{reason} refusal has no entitlement")
    end

    # Writes the check name `docs/configuration.md` documents.
    def to_s(io : IO) : Nil
      case reason
      in .group?
        io << "group"
      in .requirement?
        io << "requirement"
      in .debugged?
        io << "debugged"
      in .debuggable?
        io << "debuggable"
      in .hardened_runtime?
        io << "hardened runtime"
      in .entitlements_unreadable?
        io << "entitlements unreadable"
      in .entitlement?
        io << "entitlement " << entitlement!.identifier
      in .users?
        io << "users"
      in .groups?
        io << "groups"
      in .config?
        io << "config"
      end
    end
  end
end
