{% skip_file unless flag?(:darwin) %}

require "../address"
require "../prefix"

module Tunnelgeist
  struct Config
    # An address rule of a client configuration (CF3): the networks a
    # requested address may lie in, and for IPv4 where its point-to-point peer
    # may be.
    record AddressRule, network : Prefix, peer : Prefix? do
      # The peer prefix; raises `NilAssertionError` for a rule without one.
      def peer! : Prefix
        peer || raise NilAssertionError.new("the rule for #{network} has no peer")
      end

      # Whether *address* passes the rule: the network it describes, its
      # address with its own prefix length, lies inside `network`, so a
      # shorter prefix than the rule's fails; for IPv4 its peer must also lie
      # inside `peer`, and a rule without one passes no IPv4 address. A rule
      # of the other family never passes.
      def allows?(address : Address) : Bool
        inside = network.includes?(Prefix.new(address.address, bits: address.prefix))
        return inside if address.family.inet6?

        rule_peer = peer
        inside && !rule_peer.nil? && rule_peer.includes?(address.peer!)
      end
    end
  end
end
