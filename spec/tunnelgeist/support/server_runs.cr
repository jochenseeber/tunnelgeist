require "socket"
require "../../../src/tunnelgeist/server"

# Runs a `Tunnelgeist::Server` in a fiber and talks to it as a client, for
# the server's specs and its integration test. A spec includes the module.
module TunnelgeistServerRuns
  {% if flag?(:darwin) %}
    extend self

    # Runs *server* in a fiber; the channel receives when `run` returns.
    def start(server : Tunnelgeist::Server) : Channel(Nil)
      done = Channel(Nil).new(1)
      spawn do
        server.run
        done.send(nil)
      end
      done
    end

    # Whether `run` returned, as *done* from `start` says, within *within*.
    def returned?(done : Channel(Nil), *, within : Time::Span) : Bool
      select
      when done.receive
        true
      when timeout(within)
        false
      end
    end

    # Sends a request that does not parse on *client* and reads the reply
    # in a fiber; the channel receives the reply line.
    def ask(client : UNIXSocket) : Channel(String)
      reply = Channel(String).new(1)
      client.print("not json\n")
      spawn { reply.send(client.gets.to_s) }
      reply
    end

    # The reply line *reply* from `ask` receives within *within*, nil when
    # none arrives in time.
    def reply_within(reply : Channel(String), *, within : Time::Span) : String?
      select
      when line = reply.receive
        line
      when timeout(within)
        nil
      end
    end

    # Whether *reply* from `ask` receives a reply line within *within*.
    def received?(reply : Channel(String), *, within : Time::Span) : Bool
      !reply_within(reply, within: within).nil?
    end
  {% end %}
end
