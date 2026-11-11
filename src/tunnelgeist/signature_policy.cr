{% skip_file unless flag?(:darwin) %}

require "./entitlement"
require "./lib_cf"
require "./lib_security"
require "./refusal"
require "./signature_policy/inspection"

module Tunnelgeist
  # The optional signature check of UA11: a peer must meet at least one of
  # the configured code requirements, run with a valid signature and the
  # hardened runtime, never have been debugged, and hold none of the
  # entitlements that let another process inject code into it. A policy
  # without requirements passes every process and never calls Security;
  # `Config::Client` refuses every process for an empty `signatures` list
  # before it asks the policy.
  class SignaturePolicy
    # The refusal for a peer that meets no requirement or that Security cannot
    # read.
    UNMET = Refusal.new(reason: :requirement)

    # Compiles each requirement in Apple's code requirement language; raises
    # `ArgumentError` naming the first that does not compile and its
    # `OSStatus`.
    def initialize(requirements : Array(String))
      # Assigned before anything can raise, so `finalize` always finds it.
      @requirements = Array(LibSecurity::SecRequirementRef).new(requirements.size)
      requirements.each { |text| @requirements << compile(text) }
    end

    # Releases the compiled requirements.
    def finalize
      @requirements.each { |requirement| LibCF.CFRelease(requirement) }
    end

    # Whether no requirement is configured.
    def empty? : Bool
      @requirements.empty?
    end

    # Nil when the process *inspection* read passes, else the failed check;
    # `Refusal::Reason::Requirement` also when Security could not find or
    # read it. Raises `IO::Error` when *inspection* is closed and the policy
    # has requirements.
    def check(inspection : Inspection) : Refusal?
      return if empty?
      return UNMET unless @requirements.any? { |requirement| inspection.meets?(requirement) }

      flags = inspection.signing_flags
      return UNMET unless flags

      self.class.evaluate_flags(flags.status, entitlements: flags.entitlements)
    end

    # The rules of UA11 on a process's dynamic status word and the
    # entitlements set to true (nil when they could not be read): nil when
    # they allow it, else the failed check. `CS_GET_TASK_ALLOW` in the status
    # is refused as `Refusal::Reason::Debuggable` on top of the entitlement
    # itself.
    def self.evaluate_flags(status : UInt32, *, entitlements : Set(Entitlement)?) : Refusal?
      if !status.bits_set?(LibSecurity::CS_VALID)
        UNMET
      elsif status.bits_set?(LibSecurity::CS_DEBUGGED)
        Refusal.new(reason: :debugged)
      elsif status.bits_set?(LibSecurity::CS_GET_TASK_ALLOW)
        Refusal.new(reason: :debuggable)
      elsif !status.bits_set?(LibSecurity::CS_RUNTIME)
        Refusal.new(reason: :hardened_runtime)
      elsif entitlements.nil?
        Refusal.new(reason: :entitlements_unreadable)
      else
        held = Entitlement.values.find { |entitlement| entitlements.includes?(entitlement) }
        held && Refusal.entitlement(held)
      end
    end

    private def compile(text : String) : LibSecurity::SecRequirementRef
      raise ArgumentError.new("requirement #{text.inspect} contains a NUL byte") if text.includes?('\0')

      string = LibCF.CFStringCreateWithCString(nil, text.to_unsafe, LibCF::KCFStringEncodingUTF8)
      raise ArgumentError.new("requirement #{text.inspect} is not valid UTF-8") if string.null?

      begin
        requirement = LibSecurity::SecRequirementRef.null
        status = LibSecurity.SecRequirementCreateWithString(string, LibSecurity::KSecCSDefaultFlags,
          pointerof(requirement))
        if status != LibSecurity::ErrSecSuccess || requirement.null?
          LibCF.CFRelease(requirement) unless requirement.null?
          raise ArgumentError.new("requirement #{text.inspect} does not compile (OSStatus #{status})")
        end
        requirement
      ensure
        LibCF.CFRelease(string)
      end
    end
  end
end
