require "../spec_helper"
require "../../src/tunnelgeist/signature_policy"
require "../../src/tunnelgeist/signature_policy/entitlement_reader"

{% if flag?(:darwin) %}
  module Tunnelgeist
    # The CFBoolean values only the specs build dictionaries with.
    lib LibCF
      $kCFBooleanTrue : CFBooleanRef
      $kCFBooleanFalse : CFBooleanRef
    end
  end
{% end %}

# The signature check of UA11.
describe TunnelgeistSignaturePolicy do
  {% if flag?(:darwin) %}
    alias LibCF = Tunnelgeist::LibCF
    alias LibSecurity = Tunnelgeist::LibSecurity

    VALID              =        0x1_u32
    RUNTIME            =    0x10000_u32
    DEBUGGED           = 0x10000000_u32
    TASK_ALLOW         =        0x4_u32
    EMPTY_ENTITLEMENTS = Set(Tunnelgeist::Entitlement).new
    IDENTIFIERS        = [
      "com.apple.security.get-task-allow",
      "com.apple.security.cs.disable-library-validation",
      "com.apple.security.cs.allow-dyld-environment-variables",
      "com.apple.security.cs.allow-unsigned-executable-memory",
    ]

    def evaluate(status : UInt32, *, entitlements : Set(Tunnelgeist::Entitlement)? = EMPTY_ENTITLEMENTS) : Tunnelgeist::Refusal?
      Tunnelgeist::SignaturePolicy.evaluate_flags(status, entitlements: entitlements)
    end

    test "evaluate_flags allows a valid process with the hardened runtime" do
      assert(evaluate(VALID | RUNTIME).nil?)
    end

    test "evaluate_flags refuses a process that is not dynamically valid" do
      assert(evaluate(RUNTIME) == Tunnelgeist::Refusal.new(reason: Tunnelgeist::Refusal::Reason::Requirement))
      assert(evaluate(RUNTIME).to_s == "requirement")
    end

    test "evaluate_flags refuses a process without the hardened runtime" do
      assert(evaluate(VALID) == Tunnelgeist::Refusal.new(reason: Tunnelgeist::Refusal::Reason::HardenedRuntime))
      assert(evaluate(VALID).to_s == "hardened runtime")
    end

    test "evaluate_flags refuses a debugged process" do
      assert(evaluate(VALID | RUNTIME | DEBUGGED) == Tunnelgeist::Refusal.new(reason: Tunnelgeist::Refusal::Reason::Debugged))
      assert(evaluate(VALID | RUNTIME | DEBUGGED).to_s == "debugged")
    end

    test "evaluate_flags refuses a process whose status allows task_for_pid (get-task-allow)" do
      assert(evaluate(VALID | RUNTIME | TASK_ALLOW) == Tunnelgeist::Refusal.new(reason: Tunnelgeist::Refusal::Reason::Debuggable))
      assert(evaluate(VALID | RUNTIME | TASK_ALLOW).to_s == "debuggable")
    end

    test "evaluate_flags refuses a process whose entitlements could not be read" do
      assert(evaluate(VALID | RUNTIME, entitlements: nil) == Tunnelgeist::Refusal.new(reason: Tunnelgeist::Refusal::Reason::EntitlementsUnreadable))
      assert(evaluate(VALID | RUNTIME, entitlements: nil).to_s == "entitlements unreadable")
    end

    test "evaluate_flags refuses each entitlement that weakens the runtime" do
      Tunnelgeist::Entitlement.each do |entitlement|
        refusal = evaluate(VALID | RUNTIME, entitlements: Set{entitlement})

        assert(refusal == Tunnelgeist::Refusal.entitlement(entitlement))
        assert(refusal.to_s == "entitlement #{IDENTIFIERS[entitlement.value]}")
        assert(refusal.try(&.entitlement!) == entitlement)
      end
    end

    # An entitlements dictionary as Security returns it, with *values* by
    # entitlement identifier, wrapped as the signing information.
    def information_with(entries : Hash(String, Void*), *, key : Void*) : Void*
      keys = [] of Void*
      values = [] of Void*
      entries.each do |name, value|
        keys << LibCF.CFStringCreateWithCString(nil, name.to_unsafe, LibCF::KCFStringEncodingUTF8)
        values << value
      end
      inner = LibCF.CFDictionaryCreate(nil, keys.to_unsafe, values.to_unsafe, keys.size,
        pointerof(LibCF.kCFTypeDictionaryKeyCallBacks), pointerof(LibCF.kCFTypeDictionaryValueCallBacks))
      keys.each { |item| LibCF.CFRelease(item) }
      outer_keys = [key]
      outer_values = [inner]
      outer = LibCF.CFDictionaryCreate(nil, outer_keys.to_unsafe, outer_values.to_unsafe, 1,
        pointerof(LibCF.kCFTypeDictionaryKeyCallBacks), pointerof(LibCF.kCFTypeDictionaryValueCallBacks))
      LibCF.CFRelease(inner)
      outer
    end

    test "EntitlementReader.read counts only a CFBoolean true as set (UA11)" do
      text = LibCF.CFStringCreateWithCString(nil, "true".to_unsafe, LibCF::KCFStringEncodingUTF8)
      information = information_with({
        "com.apple.security.get-task-allow"                      => LibCF.kCFBooleanFalse,
        "com.apple.security.cs.disable-library-validation"       => LibCF.kCFBooleanTrue,
        "com.apple.security.cs.allow-dyld-environment-variables" => text,
        "com.apple.security.network.client"                      => LibCF.kCFBooleanTrue,
      }, key: LibSecurity.kSecCodeInfoEntitlementsDict)

      begin
        held = Tunnelgeist::SignaturePolicy::EntitlementReader.read(information)

        assert(held == Set{Tunnelgeist::Entitlement::DisableLibraryValidation})
      ensure
        LibCF.CFRelease(information)
        LibCF.CFRelease(text)
      end
    end

    test "EntitlementReader.read is empty without a dictionary and unreadable with only a blob" do
      empty = LibCF.CFDictionaryCreate(nil, nil, nil, 0,
        pointerof(LibCF.kCFTypeDictionaryKeyCallBacks), pointerof(LibCF.kCFTypeDictionaryValueCallBacks))
      blob = information_with({} of String => Void*, key: LibSecurity.kSecCodeInfoEntitlements)

      begin
        assert(Tunnelgeist::SignaturePolicy::EntitlementReader.read(empty) == Set(Tunnelgeist::Entitlement).new)
        assert(Tunnelgeist::SignaturePolicy::EntitlementReader.read(blob).nil?)
      ensure
        LibCF.CFRelease(empty)
        LibCF.CFRelease(blob)
      end
    end

    test "an entitlement refusal without an entitlement raises on entitlement!" do
      raised(NilAssertionError) { Tunnelgeist::Refusal.new(reason: Tunnelgeist::Refusal::Reason::Group).entitlement! }
    end

    test "a requirement that does not compile raises ArgumentError naming it" do
      error = raised(ArgumentError) { Tunnelgeist::SignaturePolicy.new(["anchor apple", "not a requirement ("]) }

      assert(error.message.to_s.includes?("not a requirement ("))
      assert(error.message.to_s.includes?("OSStatus"))
    end

    test "a requirement with a NUL byte raises ArgumentError" do
      raised(ArgumentError) { Tunnelgeist::SignaturePolicy.new(["anchor apple\0 or always"]) }
    end

    test "a policy without requirements is empty and one with requirements is not" do
      assert(Tunnelgeist::SignaturePolicy.new([] of String).empty?)
      assert(!Tunnelgeist::SignaturePolicy.new(["anchor apple generic"]).empty?)
    end
  {% end %}
end
