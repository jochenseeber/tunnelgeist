{% skip_file unless flag?(:darwin) %}

require "c/sys/types"
require "./lib_system"

module Tunnelgeist
  # The audit token accessors of libbsm (bsm/libbsm.h).
  @[Link("bsm")]
  lib LibBSM
    fun audit_token_to_euid(atoken : LibSystem::AuditToken) : ::LibC::UidT
    fun audit_token_to_egid(atoken : LibSystem::AuditToken) : ::LibC::GidT
    fun audit_token_to_pid(atoken : LibSystem::AuditToken) : ::LibC::PidT
  end
end
