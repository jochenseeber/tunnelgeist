{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  struct Refusal
    # Why the peer check refused a peer.
    enum Reason
      # Not a member of the helper's group.
      Group
      # Meets none of the configured code requirements, or Security cannot
      # read the process.
      Requirement
      # Has been debugged.
      Debugged
      # Its status word allows `task_for_pid`.
      Debuggable
      # Runs without the hardened runtime.
      HardenedRuntime
      # Its entitlements could not be read.
      EntitlementsUnreadable
      # Holds an entitlement that weakens the runtime; the refusal names it.
      Entitlement
      # Not one of the users a client configuration lists.
      Users
      # A member of none of the groups a client configuration lists.
      Groups
      # Matched by no client configuration; the log names each
      # configuration's own reason.
      Config
      # Has as many connections open as the daemon serves for one user.
      Connections
    end
  end
end
