require "../test_helper"
require "../../src/tunnelgeist/departure_watcher"
require "../../src/tunnelgeist/registry"

# The departure watcher of UA5 and UA6 on the kernel's own event socket.
describe TunnelgeistDepartureWatcher do
  {% if flag?(:darwin) %}
    alias DepartureWatcher = Tunnelgeist::DepartureWatcher

    def received?(channel : Channel(String), *, within : Time::Span) : String?
      select
      when reason = channel.receive
        reason
      when timeout(within)
        nil
      end
    end

    test "start opens the kernel event socket and close stops it" do
      failures = Channel(String).new(4)
      watcher = DepartureWatcher.new(Tunnelgeist::Registry.new, log: Log.new("tunnelgeist", Log::MemoryBackend.new, :debug),
        on_failure: ->(reason : String) { failures.send(reason) }).start
      Fiber.yield
      watcher.close
      watcher.close

      # The reading fiber sees the closed socket on its next turn; closing
      # on purpose is not a failure.
      assert(received?(failures, within: 100.milliseconds).nil?)
    end
  {% end %}
end
