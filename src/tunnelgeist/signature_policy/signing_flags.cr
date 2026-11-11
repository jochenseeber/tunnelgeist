{% skip_file unless flag?(:darwin) %}

require "../entitlement"

class Tunnelgeist::SignaturePolicy
  # What Security reports of a process's signature: its dynamic status
  # word and which `Entitlement`s it sets to true, nil when they could not
  # be read.
  record SigningFlags, status : UInt32, entitlements : Set(Entitlement)? do
    # The entitlements; raises when they could not be read.
    def entitlements! : Set(Entitlement)
      entitlements || raise NilAssertionError.new("the entitlements could not be read")
    end
  end
end
