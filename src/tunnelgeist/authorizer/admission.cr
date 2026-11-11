{% skip_file unless flag?(:darwin) %}

require "../address"
require "../config/client"
require "../prefix"
require "./client_refusal"
require "./denial"

module Tunnelgeist
  class Authorizer
    # The answer of `Authorizer#admit` for one peer: the client
    # configurations that apply to it, in configuration order, and why each
    # other one does not. A peer outside the main group is
    # `group_refused?`, and then no configuration was looked at.
    record Admission, clients : Array(Config::Client), refusals : Array(ClientRefusal),
      group_refused : Bool = false do
      # The admission of a peer outside the main group.
      def self.refused_group : Admission
        new(clients: [] of Config::Client, refusals: [] of ClientRefusal, group_refused: true)
      end

      # Whether the peer is refused: outside the main group, or no
      # configuration applies to it.
      def refused? : Bool
        clients.empty?
      end

      # Whether the peer is outside the main group.
      def group_refused? : Bool
        group_refused
      end

      # The names of the configurations that apply, for the log.
      def names : Array(String)
        clients.map(&.name)
      end

      # Nil when the applying configurations together allow every item (CD1),
      # else the first item none of them allows: the addresses in the order
      # given, then the routes. An address must pass an address rule of one
      # configuration (CF3); a route must lie inside one of its route
      # prefixes (CF5), so a route of a family no prefix has is denied.
      def allow(*, addresses : Array(Address), routes : Array(Prefix)) : Denial?
        address = addresses.find { |item| !allows?(item) }
        if address
          Denial.address(address)
        else
          route = routes.find { |item| !allows?(item) }
          route && Denial.route(route)
        end
      end

      private def allows?(address : Address) : Bool
        clients.any? { |client| client.addresses.any?(&.allows?(address)) }
      end

      private def allows?(route : Prefix) : Bool
        clients.any? { |client| client.routes.any?(&.includes?(route)) }
      end
    end
  end
end
