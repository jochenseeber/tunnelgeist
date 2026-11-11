require "../../spec_helper"
require "../../../src/tunnelgeist/config/field_path"

# The field paths errors of the configuration name.
describe Tunnelgeist::Config::FieldPath do
  {% if flag?(:darwin) %}
    alias FieldPath = Tunnelgeist::Config::FieldPath

    test "child puts a plain name into the path as it is" do
      ["a", "_", "_a1", "Web_2", "z9"].each do |name|
        assert(FieldPath.child(nil, name) == name)
        assert(FieldPath.child("clients[0]", name) == "clients[0].#{name}")
      end
    end

    test "child quotes a name that is not an ASCII letter or underscore followed by ASCII letters, digits and underscores" do
      ["", "1a", "a-b", "a b", "a.b", "a\n", "é", "ａ", "a٣", String.new(Bytes[0x61, 0xff])].each do |name|
        assert(FieldPath.child(nil, name) == name.inspect)
        assert(FieldPath.child("x", name) == "x.#{name.inspect}")
      end
    end

    test "element appends the index" do
      assert(FieldPath.element("clients", 3) == "clients[3]")
      assert(FieldPath.element(nil, 0) == "[0]")
    end
  {% end %}
end
