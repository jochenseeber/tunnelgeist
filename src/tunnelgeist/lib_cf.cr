{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  # The CoreFoundation declarations of the signature check (UA11). Only
  # `Tunnelgeist` links this framework (UC1). Declarations and values from the
  # macOS SDK's framework headers (`xcrun --show-sdk-path`, then
  # `System/Library/Frameworks/CoreFoundation.framework/Headers/...`), the
  # values and sizes checked against a C program built with that SDK:
  # `CFDictionaryKeyCallBacks` is 48 bytes, `CFDictionaryValueCallBacks` 40,
  # `CFIndex` and `CFTypeID` 8, `Boolean` 1.
  @[Link(framework: "CoreFoundation")]
  lib LibCF
    # The opaque object types (CFBase.h and the headers of each type).
    alias CFTypeRef = Void*
    alias CFAllocatorRef = Void*
    alias CFStringRef = Void*
    alias CFDataRef = Void*
    alias CFDictionaryRef = Void*
    alias CFNumberRef = Void*
    alias CFBooleanRef = Void*
    # Scalar types (CFBase.h, 64-bit; `CFNumberType` is a `CFIndex` enum in
    # CFNumber.h, `CFStringEncoding` a `UInt32` in CFString.h).
    alias CFIndex = Int64
    alias CFTypeID = UInt64
    alias Boolean = UInt8
    alias CFStringEncoding = UInt32
    alias CFNumberType = CFIndex

    # UTF-8 (CFString.h).
    KCFStringEncodingUTF8 = 0x08000100_u32
    # A signed 64-bit integer (CFNumber.h).
    KCFNumberSInt64Type = 4

    # `CFDictionaryKeyCallBacks` (CFDictionary.h): a version and five function
    # pointers. Only its address is passed.
    struct CFDictionaryKeyCallBacks
      version : CFIndex
      retain : Void*
      release : Void*
      copy_description : Void*
      equal : Void*
      hash : Void*
    end

    # `CFDictionaryValueCallBacks` (CFDictionary.h): a version and four function
    # pointers. Only its address is passed.
    struct CFDictionaryValueCallBacks
      version : CFIndex
      retain : Void*
      release : Void*
      copy_description : Void*
      equal : Void*
    end

    # The callbacks that retain and release CF objects (CFDictionary.h).
    $kCFTypeDictionaryKeyCallBacks : CFDictionaryKeyCallBacks
    $kCFTypeDictionaryValueCallBacks : CFDictionaryValueCallBacks

    # CFBase.h
    fun CFGetTypeID(cf : CFTypeRef) : CFTypeID
    fun CFRelease(cf : CFTypeRef) : Void
    # CFData.h
    fun CFDataCreate(allocator : CFAllocatorRef, bytes : UInt8*, length : CFIndex) : CFDataRef
    # CFDictionary.h
    fun CFDictionaryCreate(allocator : CFAllocatorRef, keys : Void**, values : Void**, num_values : CFIndex,
                           key_call_backs : CFDictionaryKeyCallBacks*,
                           value_call_backs : CFDictionaryValueCallBacks*) : CFDictionaryRef
    fun CFDictionaryGetTypeID : CFTypeID
    fun CFDictionaryGetValue(dict : CFDictionaryRef, key : Void*) : Void*
    # CFString.h
    fun CFStringCreateWithCString(alloc : CFAllocatorRef, c_str : UInt8*, encoding : CFStringEncoding) : CFStringRef
    # CFNumber.h
    fun CFNumberGetTypeID : CFTypeID
    fun CFNumberGetValue(number : CFNumberRef, the_type : CFNumberType, value_ptr : Void*) : Boolean
    fun CFBooleanGetTypeID : CFTypeID
    fun CFBooleanGetValue(boolean : CFBooleanRef) : Boolean
  end
end
