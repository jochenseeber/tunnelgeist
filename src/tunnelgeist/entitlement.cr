{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  # The entitlements that weaken the hardened runtime by letting another
  # process inject code into the holder. The members are in the order the
  # signature check reports them.
  enum Entitlement
    GetTaskAllow
    DisableLibraryValidation
    AllowDyldEnvironmentVariables
    AllowUnsignedExecutableMemory

    # The key of this entitlement in a signature's entitlements dictionary.
    def identifier : String
      case self
      in .get_task_allow?
        "com.apple.security.get-task-allow"
      in .disable_library_validation?
        "com.apple.security.cs.disable-library-validation"
      in .allow_dyld_environment_variables?
        "com.apple.security.cs.allow-dyld-environment-variables"
      in .allow_unsigned_executable_memory?
        "com.apple.security.cs.allow-unsigned-executable-memory"
      end
    end
  end
end
