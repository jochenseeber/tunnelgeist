{% skip_file unless flag?(:darwin) %}

require "./lib_cf"

module Tunnelgeist
  # The Security declarations of the signature check (UA11). Only
  # `Tunnelgeist` links this framework (UC1). Declarations and values from the
  # macOS SDK's framework headers (`xcrun --show-sdk-path`, then
  # `System/Library/Frameworks/Security.framework/Headers/...`), the values
  # checked against a C program built with that SDK.
  @[Link(framework: "Security")]
  lib LibSecurity
    alias OSStatus = Int32
    alias SecCSFlags = UInt32
    alias SecCodeRef = Void*
    alias SecRequirementRef = Void*

    # No error (SecBase.h).
    ErrSecSuccess = 0
    # No particular flags (CSCommon.h).
    KSecCSDefaultFlags = 0_u32
    # What `SecCodeCopySigningInformation` returns (SecCode.h): signing
    # information (`1 << 1`) and dynamic validity information (`1 << 3`).
    KSecCSSigningInformation = 2_u32
    KSecCSDynamicInformation = 8_u32

    # The dynamic status word of a running process (kern/cs_blobs.h in
    # Kernel.framework, the same values as xnu's osfmk/kern/cs_blobs.h):
    # dynamically valid, allows `task_for_pid` (the get-task-allow
    # entitlement), the hardened runtime, and debugged at some time.
    CS_VALID          = 0x00000001_u32
    CS_GET_TASK_ALLOW = 0x00000004_u32
    CS_RUNTIME        = 0x00010000_u32
    CS_DEBUGGED       = 0x10000000_u32

    # The guest attribute that names a process by its audit token, as a CFData
    # (SecCode.h).
    $kSecGuestAttributeAudit : LibCF::CFStringRef
    # The keys of the signing information (SecCode.h): the status word as a
    # CFNumber, the entitlements as a CFDictionary, and the raw entitlements
    # blob as a CFData, present also when the entitlements are not in
    # dictionary form.
    $kSecCodeInfoStatus : LibCF::CFStringRef
    $kSecCodeInfoEntitlementsDict : LibCF::CFStringRef
    $kSecCodeInfoEntitlements : LibCF::CFStringRef

    # SecRequirement.h
    fun SecRequirementCreateWithString(text : LibCF::CFStringRef, flags : SecCSFlags,
                                       requirement : SecRequirementRef*) : OSStatus
    # SecCode.h
    fun SecCodeCopyGuestWithAttributes(host : SecCodeRef, attributes : LibCF::CFDictionaryRef, flags : SecCSFlags,
                                       guest : SecCodeRef*) : OSStatus
    fun SecCodeCheckValidity(code : SecCodeRef, flags : SecCSFlags, requirement : SecRequirementRef) : OSStatus
    fun SecCodeCopySigningInformation(code : SecCodeRef, flags : SecCSFlags,
                                      information : LibCF::CFDictionaryRef*) : OSStatus
  end
end
