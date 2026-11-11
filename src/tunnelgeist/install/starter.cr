{% skip_file unless flag?(:darwin) %}

require "json"

module Tunnelgeist
  class Install
    # The starter configuration `install` writes when there is none (CF6):
    # the socket, the main group, the `clients.d` includes and one client
    # that applies to every member of the group and allows the private
    # IPv4 ranges and the IPv6 unique local range for addresses and
    # routes.
    module Starter
      # The private IPv4 ranges, each the network and the peer of an
      # address rule.
      IPV4_NETWORKS = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
      # The IPv6 unique local range; IPv6 address rules have no peer.
      IPV6_NETWORK = "fc00::/7"
      # The directory beside the main file for client configurations.
      CLIENTS_DIRECTORY = "clients.d"
      # The include pattern for one client configuration per file.
      INCLUDE = "#{CLIENTS_DIRECTORY}/*.json"
      # The name of the starter's client configuration.
      CLIENT_NAME = "default"

      # The starter configuration for *socket* and the main group *group*,
      # indented by two spaces and ending in a newline.
      def self.json(*, socket : String, group : String) : String
        text = JSON.build(indent: "  ") do |json|
          json.object do
            json.field "socket", socket
            json.field "group", group
            json.field "includes", [INCLUDE]
            json.field "clients" do
              json.array { client(json) }
            end
          end
        end
        "#{text}\n"
      end

      private def self.client(json : JSON::Builder) : Nil
        json.object do
          json.field "name", CLIENT_NAME
          json.field "addresses" do
            json.array do
              IPV4_NETWORKS.each do |network|
                json.object do
                  json.field "network", network
                  json.field "peer", network
                end
              end
              json.object { json.field "network", IPV6_NETWORK }
            end
          end
          json.field "routes", IPV4_NETWORKS + [IPV6_NETWORK]
        end
      end
    end
  end
end
