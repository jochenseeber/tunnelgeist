{% skip_file unless flag?(:darwin) %}

require "c/stddef"

module Tunnelgeist
  module Launchd
    # The launchd socket activation call (launch.h), which the standard
    # library's `LibC` lacks.
    lib LibLaunch
      # Hands the process the descriptors launchd opened for the socket entry
      # *name* of its job (launch.h). Returns 0 or an errno value (`ESRCH` when
      # launchd does not manage the process, `ENOENT` for an unknown name); on
      # success *fds* points to a `malloc`ed array of *cnt* descriptors the
      # caller frees.
      fun launch_activate_socket(name : ::LibC::Char*, fds : ::LibC::Int**, cnt : ::LibC::SizeT*) : ::LibC::Int
    end
  end
end
