{% skip_file unless flag?(:darwin) %}

require "../authorizer/admission"
require "../peer"

module Tunnelgeist
  class Handler
    # A peer the handler admitted and the client configurations that apply
    # to it, which judge the items of its request (CA3).
    private record Admitted, peer : Peer, admission : Authorizer::Admission
  end
end
