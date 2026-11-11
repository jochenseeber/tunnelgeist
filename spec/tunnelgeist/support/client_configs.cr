require "../../../src/tunnelgeist/authorizer/admission"
require "../../../src/tunnelgeist/authorizer/client_refusal"
require "../../../src/tunnelgeist/config/address_rule"
require "../../../src/tunnelgeist/config/client"
require "../../../src/tunnelgeist/membership"
require "../../../src/tunnelgeist/prefix"
require "../../../src/tunnelgeist/refusal"
require "../../../src/tunnelgeist/signature_policy"

# Client configurations and admissions built by hand for the specs of the
# authorizer and of the handlers that ask it. A spec includes the module; a
# fixture class calls the same methods on the module itself.
module TunnelgeistClientConfigs
  {% if flag?(:darwin) %}
    extend self

    def prefix(text : String) : Tunnelgeist::Prefix
      Tunnelgeist::Prefix.parse(text)
    end

    def rule(network : String, *, peer : String? = nil) : Tunnelgeist::Config::AddressRule
      Tunnelgeist::Config::AddressRule.new(network: prefix(network), peer: peer.try { |text| prefix(text) })
    end

    # A client configuration; the fields left out restrict nothing and the
    # allowances left out allow nothing.
    def client(name : String, *, users : Array(UInt32)? = nil, groups : Array(Tunnelgeist::Membership)? = nil,
               signatures : Array(String)? = nil,
               addresses : Array(Tunnelgeist::Config::AddressRule) = [] of Tunnelgeist::Config::AddressRule,
               routes : Array(String) = [] of String) : Tunnelgeist::Config::Client
      Tunnelgeist::Config::Client.new(name: name, users: users, groups: groups,
        policy: signatures.try { |requirements| Tunnelgeist::SignaturePolicy.new(requirements) },
        addresses: addresses, routes: routes.map { |route| prefix(route) })
    end

    # The admission of a peer *clients* apply to.
    def applying(clients : Array(Tunnelgeist::Config::Client)) : Tunnelgeist::Authorizer::Admission
      Tunnelgeist::Authorizer::Admission.new(clients: clients, refusals: [] of Tunnelgeist::Authorizer::ClientRefusal)
    end

    # The admission of one configuration `open` that applies to every peer
    # and allows every address and route of both families, as the daemon
    # did before client configurations.
    def open_admission : Tunnelgeist::Authorizer::Admission
      applying([client("open", addresses: [rule("0.0.0.0/0", peer: "0.0.0.0/0"), rule("::/0")],
        routes: ["0.0.0.0/0", "::/0"])])
    end

    def client_refusal(name : String, *, reason : Tunnelgeist::Refusal::Reason) : Tunnelgeist::Authorizer::ClientRefusal
      Tunnelgeist::Authorizer::ClientRefusal.new(name: name, refusal: Tunnelgeist::Refusal.new(reason: reason))
    end
  {% end %}
end
