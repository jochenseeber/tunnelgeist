require "../spec_helper"
require "../../src/tunnelgeist/protocol"

# The protocol document, `docs/protocol.md`: every example line in it is what
# the code emits (TT2).
module ProtocolDocument
end

describe ProtocolDocument do
  {% if flag?(:darwin) %}
    # The lines of every fenced block tagged `json`.
    def example_lines : Array(String)
      lines = [] of String
      inside = false
      File.each_line(File.join(__DIR__, "..", "..", "docs", "protocol.md")) do |line|
        if inside
          if line.strip == "```"
            inside = false
          else
            lines << line unless line.blank?
          end
        elsif line.strip == "```json"
          inside = true
        end
      end
      lines
    end

    test "lists a request and a reply for every operation" do
      ops = example_lines.select(&.includes?(%("op"))).map { |line| Tunnelgeist::Protocol::Request.parse(line).operation.wire }
      assert(ops.sort == ["add_address", "add_route", "create", "remove_address", "remove_route"])
      assert(example_lines.reject(&.includes?(%("op"))).size >= 5)
    end

    test "every request example parses and re-encodes to the same line" do
      example_lines.select(&.includes?(%("op"))).each do |line|
        assert(Tunnelgeist::Protocol::Request.parse(line).to_json == line)
      end
    end

    test "every reply example parses and re-encodes to the same line" do
      example_lines.reject(&.includes?(%("op"))).each do |line|
        assert(Tunnelgeist::Protocol::Reply.parse(line).to_json == line)
      end
    end
  {% end %}
end
