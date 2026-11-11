require "../spec_helper"
require "../../src/tunnelgeist/version"

{% if flag?(:darwin) %}
  describe Tunnelgeist do
    test "VERSION is read from shard.yml" do
      assert(Tunnelgeist::VERSION == "1.0.0-dev")
    end
  end
{% end %}
