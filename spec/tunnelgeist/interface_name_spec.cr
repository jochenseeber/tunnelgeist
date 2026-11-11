require "../spec_helper"
require "../../src/tunnelgeist/interface_name"

# The name of a utun interface.
describe Tunnelgeist::InterfaceName do
  {% if flag?(:darwin) %}
    alias InterfaceName = Tunnelgeist::InterfaceName

    test "parse? reads the unit N of utunN" do
      assert(InterfaceName.parse?("utun0").try(&.unit) == 0_u32)
      assert(InterfaceName.parse?("utun12").try(&.unit) == 12_u32)
      assert(InterfaceName.parse?("utun4294967294").try(&.unit) == 4_294_967_294_u32)
    end

    test "parse? rejects other names and a unit the kernel cannot address" do
      ["utun4294967295", "utun99999999999", "utun007", "utun", "en0", " utun1", "utun1 ", ""].each do |text|
        assert(InterfaceName.parse?(text).nil?)
      end
    end

    test "parse? refuses a unit that is not plain ASCII decimal" do
      ["utun٣", "utun１", "utun1\n", "utun\n1", "utun+1", "utun-0", "utun 1", "UTUN1", "Utun1", "utun0x1", "utun1_0",
       "utun00", String.new(Bytes[0x75, 0x74, 0x75, 0x6e, 0x31, 0xff])].each do |text|
        assert(InterfaceName.parse?(text).nil?)
      end
    end

    test "new raises ArgumentError naming the text it refuses" do
      error = raised(ArgumentError) { InterfaceName.new("en0") }

      assert(error.message == %(name must be utun and a unit number, such as utun7, got "en0"))
    end

    test "to_s is the name and equal names are equal" do
      name = InterfaceName.new("utun7")

      assert(name.to_s == "utun7")
      assert("name=#{name}" == "name=utun7")
      assert(name == InterfaceName.new("utun7"))
      assert(name.hash == InterfaceName.new("utun7").hash)
      assert(name != InterfaceName.new("utun8"))
    end
  {% end %}
end
