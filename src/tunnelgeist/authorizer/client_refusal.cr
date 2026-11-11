{% skip_file unless flag?(:darwin) %}

require "../refusal"

module Tunnelgeist
  class Authorizer
    # Why the client configuration *name* does not apply to a peer, for the
    # `name=reason` pairs of the refusal log line (CA2).
    record ClientRefusal, name : String, refusal : Refusal
  end
end
