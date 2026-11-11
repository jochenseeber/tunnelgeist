{% skip_file unless flag?(:darwin) %}

require "../lib_cf"
require "../lib_security"
require "../lib_system"
require "../peer"
require "./entitlement_reader"
require "./signing_flags"

class Tunnelgeist::SignaturePolicy
  # What Security says about one peer's process (UA11), read once per
  # request and shared by every policy that judges the peer: its `SecCode`,
  # found by the audit token so a later process that reuses the pid is not
  # judged instead, and its signing information, read the first time a policy
  # asks for it. Holds the `SecCode` until `close` or until it is collected.
  class Inspection
    # The `SecCode` of a process Security did not find.
    private NONE = LibSecurity::SecCodeRef.null

    @code : LibSecurity::SecCodeRef
    @flags : SigningFlags? = nil
    @flags_read = false
    @closed = false

    # Looks up the process *peer* names. Never raises: when Security cannot
    # find the process the inspection is not `found?` and meets nothing.
    def self.of(peer : Peer) : Inspection
      new(guest(peer.token))
    end

    private def initialize(@code : LibSecurity::SecCodeRef)
    end

    # Releases the `SecCode` unless `close` already has.
    def finalize
      close
    end

    # Releases the `SecCode`; later calls do nothing. Asking a closed
    # inspection raises.
    def close : Nil
      return if @closed

      @closed = true
      LibCF.CFRelease(@code) unless @code.null?
      @code = NONE
    end

    # Whether `close` has run.
    def closed? : Bool
      @closed
    end

    # Whether Security found the process. Raises `IO::Error` when closed.
    def found? : Bool
      !code.null?
    end

    # Whether the process meets *requirement*: false when Security did not
    # find it. Raises `IO::Error` when closed.
    def meets?(requirement : LibSecurity::SecRequirementRef) : Bool
      found = code
      return false if found.null?

      LibSecurity.SecCodeCheckValidity(found, LibSecurity::KSecCSDefaultFlags, requirement) == LibSecurity::ErrSecSuccess
    end

    # The dynamic status word of the process and which `Entitlement`s it
    # sets to true (see `EntitlementReader.read`), or nil when Security did
    # not find the process or cannot read its signing information. Read on
    # the first call and kept. Raises `IO::Error` when closed.
    def signing_flags : SigningFlags?
      found = code
      unless @flags_read
        @flags = read_signing_flags(found) unless found.null?
        @flags_read = true
      end
      @flags
    end

    # The signing information; raises `NilAssertionError` when Security did
    # not find the process or cannot read it, and `IO::Error` when closed.
    def signing_flags! : SigningFlags
      signing_flags || raise NilAssertionError.new("the signing information could not be read")
    end

    # The `SecCode`, null when Security did not find the process; raises
    # `IO::Error` when closed, because the reference is released then.
    private def code : LibSecurity::SecCodeRef
      raise IO::Error.new("Closed inspection") if @closed

      @code
    end

    # The running process *token* names, as a `SecCode` the caller releases,
    # or null when Security cannot find it.
    private def self.guest(token : LibSystem::AuditToken) : LibSecurity::SecCodeRef
      data = LibCF.CFDataCreate(nil, pointerof(token).as(UInt8*), sizeof(LibSystem::AuditToken))
      return NONE if data.null?

      begin
        keys = StaticArray[LibSecurity.kSecGuestAttributeAudit]
        values = StaticArray[data]
        attributes = LibCF.CFDictionaryCreate(nil, keys.to_unsafe.as(Void**), values.to_unsafe.as(Void**), 1,
          pointerof(LibCF.kCFTypeDictionaryKeyCallBacks), pointerof(LibCF.kCFTypeDictionaryValueCallBacks))
        return NONE if attributes.null?

        begin
          code = LibSecurity::SecCodeRef.null
          status = LibSecurity.SecCodeCopyGuestWithAttributes(nil, attributes, LibSecurity::KSecCSDefaultFlags,
            pointerof(code))
          if status != LibSecurity::ErrSecSuccess && !code.null?
            LibCF.CFRelease(code)
            code = NONE
          end
          code
        ensure
          LibCF.CFRelease(attributes)
        end
      ensure
        LibCF.CFRelease(data)
      end
    end

    # The signing information of *code* as `SigningFlags`, or nil when
    # Security cannot read it.
    private def read_signing_flags(code : LibSecurity::SecCodeRef) : SigningFlags?
      flags = LibSecurity::KSecCSDynamicInformation | LibSecurity::KSecCSSigningInformation
      information = LibCF::CFDictionaryRef.null
      status = LibSecurity.SecCodeCopySigningInformation(code, flags, pointerof(information))
      if status != LibSecurity::ErrSecSuccess || information.null?
        LibCF.CFRelease(information) unless information.null?
        return
      end

      begin
        SigningFlags.new(status: status_word(information), entitlements: EntitlementReader.read(information))
      ensure
        LibCF.CFRelease(information)
      end
    end

    # The `kSecCodeInfoStatus` number of *information*, 0 (not valid) when
    # it is missing or not a number.
    private def status_word(information : LibCF::CFDictionaryRef) : UInt32
      number = LibCF.CFDictionaryGetValue(information, LibSecurity.kSecCodeInfoStatus)
      return 0_u32 if number.null? || LibCF.CFGetTypeID(number) != LibCF.CFNumberGetTypeID

      value = 0_i64
      return 0_u32 if LibCF.CFNumberGetValue(number, LibCF::KCFNumberSInt64Type, pointerof(value).as(Void*)) == 0

      value.to_u32!
    end
  end
end
