{% skip_file unless flag?(:darwin) %}

require "./authorizer/admission"
require "./authorizer/client_refusal"
require "./config"
require "./peer"
require "./signature_policy/inspection"

module Tunnelgeist
  # Applies a `Config` to peers (CA2): which client configurations apply to
  # a peer, as an `Admission` that then judges the addresses and routes the
  # peer asks for.
  class Authorizer
    def initialize(@config : Config)
    end

    # Checks the main group first; a peer outside it is refused before any
    # client configuration is looked at. Then judges every configuration
    # (CF4). Security reads the peer at most once, when the first
    # configuration that lists signatures is reached, and that read serves
    # every such configuration. Raises `IO::Error` as `Membership#member?`
    # does.
    def admit(peer : Peer) : Admission
      if @config.membership.member?(peer)
        judge(peer)
      else
        Admission.refused_group
      end
    end

    # The admission of *peer*, a member of the main group.
    private def judge(peer : Peer) : Admission
      clients = [] of Config::Client
      refusals = [] of ClientRefusal
      inspection : SignaturePolicy::Inspection? = nil
      begin
        @config.clients.each do |client|
          inspection ||= SignaturePolicy::Inspection.of(peer) if client.policy
          refusal = client.applies?(peer, inspection: inspection)
          if refusal
            refusals << ClientRefusal.new(name: client.name, refusal: refusal)
          else
            clients << client
          end
        end
      ensure
        inspection.try(&.close)
      end
      Admission.new(clients: clients, refusals: refusals)
    end
  end
end
