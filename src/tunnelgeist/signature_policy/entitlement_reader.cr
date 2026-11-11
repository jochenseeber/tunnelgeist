{% skip_file unless flag?(:darwin) %}

require "../entitlement"
require "../lib_cf"
require "../lib_security"

class Tunnelgeist::SignaturePolicy
  # Reads which `Entitlement`s a process holds from the signing information
  # Security returns for it.
  module EntitlementReader
    # Which `Entitlement`s *information*'s entitlements dictionary sets to
    # a CFBoolean true; any other value is not set. Only when neither the
    # dictionary nor the raw entitlements blob is present does the process
    # have no entitlements. Nil, unreadable, when the dictionary is not a
    # CFDictionary or is absent while the blob is present (entitlements not
    # in dictionary form, SecCode.h). *information* stays owned by the
    # caller.
    def self.read(information : LibCF::CFDictionaryRef) : Set(Entitlement)?
      result = Set(Entitlement).new
      dictionary = LibCF.CFDictionaryGetValue(information, LibSecurity.kSecCodeInfoEntitlementsDict)
      if dictionary.null?
        blob = LibCF.CFDictionaryGetValue(information, LibSecurity.kSecCodeInfoEntitlements)
        found = blob.null? ? result : nil
        return found
      end
      return if LibCF.CFGetTypeID(dictionary) != LibCF.CFDictionaryGetTypeID

      Entitlement.each do |entitlement|
        key = LibCF.CFStringCreateWithCString(nil, entitlement.identifier.to_unsafe, LibCF::KCFStringEncodingUTF8)
        # Cannot ask, so assume the worst.
        next result << entitlement if key.null?

        begin
          value = LibCF.CFDictionaryGetValue(dictionary, key)
          if !value.null? && LibCF.CFGetTypeID(value) == LibCF.CFBooleanGetTypeID && LibCF.CFBooleanGetValue(value) != 0
            result << entitlement
          end
        ensure
          LibCF.CFRelease(key)
        end
      end
      result
    end
  end
end
