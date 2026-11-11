require "../spec_helper"
require "../../src/tunnelgeist/protocol"

# The JSON-lines protocol of the tunnelgeist daemon (UP1 to UP5): the
# requests with their validation (UP4) and the reply.
describe Tunnelgeist::Protocol do
  {% if flag?(:darwin) %}
    alias Protocol = Tunnelgeist::Protocol

    # Client text where the JSON parser expects another token; a syntax
    # error names only the position, never the token.
    CLIENT_TEXT = "client-token-0123456789"
    UTUN7       = Tunnelgeist::InterfaceName.new("utun7")

    def parse_error(line : String) : String
      raised(Protocol::Error) { Protocol::Request.parse(line) }.message.to_s
    end

    def create_json(*, name = %("utun7"), mtu = "1280", addresses = %([{"address": "10.77.0.2", "prefix": 24, "peer": "10.77.0.1"}]), routes = %(["10.99.0.0/16", "fd99::/48"]), extra = "") : String
      %({"version": 1, "op": "create", "name": #{name}, "mtu": #{mtu}, "addresses": #{addresses}, "routes": #{routes}#{extra}})
    end

    def route_json(*, op = "add_route", route = "10.99.0.0/16", name = "utun7", extra = "") : String
      %({"version": 1, "op": "#{op}", "name": "#{name}", "route": "#{route}"#{extra}})
    end

    def address_json(*, op = "add_address", address = %({"address": "fd77::2", "prefix": 64})) : String
      %({"version": 1, "op": "#{op}", "name": "utun7", "address": #{address}})
    end

    test "constants carry the limits of the specification" do
      assert(Protocol::VERSION == 1)
      assert(Protocol::MAX_REQUEST == 65_536)
      assert(Protocol::REQUEST_TIMEOUT == 5.seconds)
      assert(Protocol::MTU_RANGE == (1_280..65_535))
      assert(Protocol::MAX_ADDRESSES == 16)
      assert(Protocol::MAX_ROUTES == 64)
      assert(Protocol::UNKNOWN_DEVICE == "unknown device")
    end

    test "parses the create request of UP2" do
      request = Protocol::Request.parse(create_json).as(Protocol::Create)
      assert(request.name == UTUN7)
      assert(request.mtu == 1_280)
      assert(request.addresses.size == 1)
      assert(request.addresses[0].address.address == "10.77.0.2")
      assert(request.addresses[0].prefix == 24)
      assert(request.addresses[0].peer!.address == "10.77.0.1")
      assert(request.routes.map(&.to_s) == ["10.99.0.0/16", "fd99::/48"])
    end

    test "create takes a null or missing name as the kernel's choice" do
      assert(Protocol::Request.parse(create_json(name: "null")).as(Protocol::Create).name.nil?)
      line = %({"version": 1, "op": "create", "mtu": 1500, "addresses": [], "routes": []})
      assert(Protocol::Request.parse(line).as(Protocol::Create).name.nil?)
    end

    test "parses an IPv6 address without a peer" do
      request = Protocol::Request.parse(address_json).as(Protocol::AddAddress)
      assert(request.name == UTUN7)
      assert(request.address.address.address == "fd77::2")
      assert(request.address.peer.nil?)
    end

    test "parses the other operations" do
      assert(Protocol::Request.parse(route_json(op: "add_route")).as(Protocol::AddRoute).route.to_s == "10.99.0.0/16")
      assert(Protocol::Request.parse(route_json(op: "remove_route")).is_a?(Protocol::RemoveRoute))
      assert(Protocol::Request.parse(address_json(op: "remove_address")).is_a?(Protocol::RemoveAddress))
    end

    test "round-trips every request type through to_json and parse" do
      v4 = Tunnelgeist::Address.new(Socket::IPAddress.new("10.77.0.2", 0), prefix: 24, peer: Socket::IPAddress.new("10.77.0.1", 0))
      v6 = Tunnelgeist::Address.new(Socket::IPAddress.new("fd77::2", 0), prefix: 64)
      prefix = Tunnelgeist::Prefix.parse("fd99::/48")
      requests = [
        Protocol::Create.new(name: UTUN7, mtu: 1_400, addresses: [v4, v6], routes: [prefix]),
        Protocol::Create.new(name: nil, mtu: 65_535, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix),
        Protocol::AddAddress.new(name: UTUN7, address: v4),
        Protocol::RemoveAddress.new(name: UTUN7, address: v6),
        Protocol::AddRoute.new(name: UTUN7, route: prefix),
        Protocol::RemoveRoute.new(name: UTUN7, route: prefix),
      ] of Protocol::Request
      requests.each do |request|
        assert(Protocol::Request.parse(request.to_json) == request)
      end
    end

    test "to_json writes the shapes of UP2 and UP3" do
      v6 = Tunnelgeist::Address.new(Socket::IPAddress.new("fd77::2", 0), prefix: 64)
      line = Protocol::AddAddress.new(name: UTUN7, address: v6).to_json
      assert(line == %({"version":1,"op":"add_address","name":"utun7","address":{"address":"fd77::2","prefix":64}}))
    end

    test "rejects malformed JSON" do
      assert(parse_error("{").starts_with?("malformed JSON"))
      assert(parse_error("").starts_with?("malformed JSON"))
      assert(parse_error("[1]") == "request must be a JSON object")
    end

    test "a number out of range is malformed JSON at its first character" do
      assert(parse_error(%({"version": 99999999999999999999, "op": "create"})) == "malformed JSON at line 1, column 13")
      assert(parse_error(%({"version": 1e999, "op": "create"})) == "malformed JSON at line 1, column 13")
    end

    test "rejects anything after the request object, before reading a field" do
      assert(parse_error("#{route_json} {}").starts_with?("malformed JSON"))
      assert(parse_error(%({"version": 1, "op": "destroy", "evil": 1} x)).starts_with?("malformed JSON"))
      assert(raised(Protocol::Error) { Protocol::Reply.parse(%({"ok": true} 1)) }.message.to_s.starts_with?("malformed JSON"))
    end

    test "malformed JSON names the position but never the text, so client text cannot reach the log" do
      text = CLIENT_TEXT

      unquoted = parse_error(%({"version": 1, "op": "add_route", "name": #{text}}))
      colonless = parse_error(%({"name" "#{text}"}))
      reply = raised(Protocol::Error) { Protocol::Reply.parse(%({"ok": true, "error" "#{text}"})) }.message.to_s

      [unquoted, colonless, reply].each do |message|
        assert(!message.includes?(text))
        assert(!message.includes?(text[0, 8]))
        assert(message.matches?(/\Amalformed JSON at line \d+, column \d+\z/))
      end
    end

    test "rejects a version other than 1" do
      assert(parse_error(%({"version": 2, "op": "add_route"})) == "unsupported version 2")
      assert(parse_error(%({"op": "add_route"})) == "missing field version")
      assert(parse_error(%({"version": "1", "op": "add_route"})) == "field version must be an integer")
    end

    test "rejects an unknown or missing op" do
      assert(parse_error(%({"version": 1, "op": "destroy"})) == %(unknown op "destroy"))
      assert(parse_error(%({"version": 1})) == "missing field op")
      assert(parse_error(%({"version": 1, "op": 5})) == "field op must be a string")
    end

    test "rejects an op that is not spelled exactly as on the wire" do
      ["Create", "ADD_ROUTE", "addaddress", "remove-route", ""].each do |text|
        error = raised(Protocol::Error) { Protocol::Request.parse(%({"version": 1, "op": "#{text}"})) }

        assert(error.message == %(unknown op #{text.inspect}))
        assert(error.field! == "op")
      end
    end

    test "Operation.from_wire? matches the wire name exactly" do
      assert(Protocol::Operation.from_wire?("create") == Protocol::Operation::Create)
      assert(Protocol::Operation.from_wire?("remove_route") == Protocol::Operation::RemoveRoute)
      assert(Protocol::Operation.from_wire?("Create").nil?)
      assert(Protocol::Operation.from_wire?("addaddress").nil?)
      assert(Protocol::Operation.from_wire?("AddAddress").nil?)
    end

    test "every operation round-trips through its wire name" do
      Protocol::Operation.each do |operation|
        assert(Protocol::Operation.from_wire?(operation.wire) == operation)
      end
    end

    test "a parsed request reports its operation" do
      assert(Protocol::Request.parse(route_json).operation == Protocol::Operation::AddRoute)
      assert(Protocol::Request.parse(route_json(op: "remove_route")).operation == Protocol::Operation::RemoveRoute)
    end

    test "each request type names its operation, and a request carries the protocol version" do
      assert(Protocol::Create.operation == Protocol::Operation::Create)
      assert(Protocol::AddAddress.operation == Protocol::Operation::AddAddress)
      assert(Protocol::RemoveAddress.operation == Protocol::Operation::RemoveAddress)
      assert(Protocol::AddRoute.operation == Protocol::Operation::AddRoute)
      assert(Protocol::RemoveRoute.operation == Protocol::Operation::RemoveRoute)

      prefix = Tunnelgeist::Prefix.parse("10.99.0.0/16")
      built = Protocol::RemoveRoute.new(name: UTUN7, route: prefix)
      assert(built.operation == Protocol::Operation::RemoveRoute)
      assert(built.version == Protocol::VERSION)
      assert(Protocol::Request.parse(route_json).version == Protocol::VERSION)
    end

    test "from_json of one request type checks its version, its op and its values like Request.parse" do
      assert(Protocol::Create.from_json(create_json) == Protocol::Request.parse(create_json))
      assert(Protocol::AddRoute.from_json(route_json).route.to_s == "10.99.0.0/16")

      version = raised(Protocol::Error) { Protocol::AddRoute.from_json(route_json.sub(%("version": 1), %("version": 2))) }
      assert(version.message == "unsupported version 2")
      assert(version.field! == "version")

      op = raised(Protocol::Error) { Protocol::AddRoute.from_json(route_json(op: "remove_route")) }
      assert(op.message == %(op "remove_route" is not "add_route"))
      assert(op.field! == "op")

      assert(raised(Protocol::Error) { Protocol::Create.from_json(create_json(mtu: "10")) }.message == "mtu 10 outside 1280..65535")
      assert(raised(Protocol::Error) { Protocol::Create.from_json(create_json(extra: %(, "evil": 1))) }.field! == "evil")
    end

    test "from_json raises only Protocol::Error and never quotes the line" do
      after = raised(Protocol::Error) { Protocol::AddRoute.from_json(%(#{route_json} "#{CLIENT_TEXT}")) }
      unquoted = raised(Protocol::Error) { Protocol::AddRoute.from_json(%({"version": 1, "op": "add_route", "name": "utun7" "#{CLIENT_TEXT}"})) }
      [after, unquoted].each do |error|
        assert(error.message.to_s.matches?(/\Amalformed JSON at line \d+, column \d+\z/))
        assert(!error.message.to_s.includes?(CLIENT_TEXT[0, 8]))
        assert(error.field.nil?)
      end

      ok = raised(Protocol::Error) { Protocol::Reply.from_json(%({"ok": 1})) }
      assert(ok.message == "field ok must be a boolean")
      assert(ok.field! == "ok")
    end

    test "rejects a line that is not valid UTF-8 before its syntax" do
      line = route_json(name: "utun\xC3")
      [
        raised(Protocol::Error) { Protocol::Request.parse(line) },
        raised(Protocol::Error) { Protocol::AddRoute.from_json(line) },
        raised(Protocol::Error) { Protocol::Request.parse("\xFF{") },
      ].each do |error|
        assert(error.message == "request is not valid UTF-8")
        assert(error.field.nil?)
      end
      reply = raised(Protocol::Error) { Protocol::Reply.parse(%({"ok": false, "error": "\xC3"})) }
      assert(reply.message == "reply is not valid UTF-8")
    end

    test "rejects a field given twice in any object, naming it" do
      cases = {
        "version" => %({"version": "x", "op": "add_route", "version": 1}),
        "op"      => route_json(extra: %(, "op": "add_route")),
        "prefix"  => address_json(address: %({"address": "fd77::2", "prefix": 64, "prefix": 64})),
      }
      cases.each do |field, line|
        error = raised(Protocol::Error) { Protocol::Request.parse(line) }
        assert(error.message == %(duplicate field "#{field}"))
        assert(error.field! == field)
      end
      reply = raised(Protocol::Error) { Protocol::Reply.parse(%({"ok": true, "name": 5, "name": "utun7"})) }
      assert(reply.message == %(duplicate field "name"))
    end

    test "a list over its limit is refused for its length before any element is read" do
      assert(parse_error(create_json(addresses: "[#{(["1"] * 17).join(",")}]")) == "too many addresses: 17, at most 16")
      assert(parse_error(create_json(routes: "[#{(["1"] * 65).join(",")}]")) == "too many routes: 65, at most 64")
    end

    test "a list element nested as deep as the parser allows gets the error of its value" do
      deep = "#{"[" * 400}#{"]" * 400}"
      assert(parse_error(create_json(routes: "[#{deep}]")) == "route must be a string")
      assert(parse_error(create_json(addresses: "[#{deep}]")) == "address must be a JSON object")
      line = create_json(addresses: %([{"address": "fd77::2", "prefix": 64, "x": #{deep}}]))
      assert(parse_error(line) == %(unknown field "x"))
    end

    test "Reply.parse names a missing ok before an unknown field" do
      assert(raised(Protocol::Error) { Protocol::Reply.parse(%({"x": 1})) }.message == "missing field ok")
    end

    test "from_json with a root member is refused with Protocol::Error, without reading the line" do
      line = %({"r": #{route_json}} "#{CLIENT_TEXT}")
      [
        raised(Protocol::Error) { Protocol::AddRoute.from_json(line, "r") },
        raised(Protocol::Error) { Protocol::AddRoute.from_json(IO::Memory.new(line), "r") },
        raised(Protocol::Error) { Protocol::Reply.from_json(%({"r": {"ok": true}}), "r") },
      ].each do |error|
        assert(!error.message.to_s.includes?(CLIENT_TEXT[0, 8]))
        assert(error.message.to_s.includes?("root"))
        assert(error.field.nil?)
      end
    end

    test "a line over the limit gets the length error through parse and both from_json, even cut inside a character" do
      head = create_json(extra: %(, "x": "))
      line = "#{head}#{"a" * (Protocol::MAX_REQUEST - head.bytesize)}üab\"}"
      assert(line.bytesize == 65_542)
      assert(line.byte_slice(Protocol::MAX_REQUEST, 2) == "ü")

      expected = "request longer than #{Protocol::MAX_REQUEST} bytes"
      assert(parse_error(line) == expected)
      assert(raised(Protocol::Error) { Protocol::Create.from_json(line) }.message == expected)
      assert(raised(Protocol::Error) { Protocol::Create.from_json(IO::Memory.new(line)) }.message == expected)
    end

    test "a reply is limited to MAX_REPLY bytes through parse and both from_json" do
      line = %({"ok": false, "error": "#{"a" * Protocol::MAX_REPLY}"})
      expected = "reply longer than #{Protocol::MAX_REPLY} bytes"
      assert(raised(Protocol::Error) { Protocol::Reply.parse(line) }.message == expected)
      assert(raised(Protocol::Error) { Protocol::Reply.from_json(line) }.message == expected)
      assert(raised(Protocol::Error) { Protocol::Reply.from_json(IO::Memory.new(line)) }.message == expected)
      assert(Tunnelgeist::Protocol::MAX_REPLY == 65_536)
    end

    test "Reply.from_json reads what Reply.parse reads" do
      line = %({"ok":true,"name":"utun7"})
      assert(Protocol::Reply.from_json(line) == Protocol::Reply.parse(line))
    end

    test "rejects a name that is not utunN" do
      assert(parse_error(create_json(name: %("eth0"))) == %(invalid device name "eth0"))
      assert(parse_error(route_json(name: "utun")) == %(invalid device name "utun"))
      assert(parse_error(route_json(name: "utun1x")) == %(invalid device name "utun1x"))
    end

    test "rejects an MTU outside 1280..65535" do
      assert(parse_error(create_json(mtu: "1279")) == "mtu 1279 outside 1280..65535")
      assert(parse_error(create_json(mtu: "65536")) == "mtu 65536 outside 1280..65535")
      assert(parse_error(create_json(mtu: "99999999999999999999")).starts_with?("malformed JSON"))
      assert(parse_error(create_json(mtu: "4294967296")) == "field mtu must be an integer")
    end

    test "rejects an address or route that does not parse" do
      assert(parse_error(create_json(routes: %(["nonsense"]))).starts_with?(%(invalid route "nonsense")))
      assert(parse_error(create_json(routes: %(["10.99.0.0"]))).starts_with?(%(invalid route "10.99.0.0")))
      line = create_json(addresses: %([{"address": "10.77.0.x", "prefix": 24, "peer": "10.77.0.1"}]))
      assert(parse_error(line).starts_with?(%(invalid address "10.77.0.x")))
      line = create_json(addresses: %([{"address": "10.77.0.2", "prefix": 24, "peer": "bad"}]))
      assert(parse_error(line).starts_with?(%(invalid peer "bad")))
    end

    test "rejects a route with host bits set" do
      assert(parse_error(route_json(route: "10.99.0.1/16")) == "route 10.99.0.1/16 has host bits set")
      assert(parse_error(create_json(routes: %(["fd99::1/48"]))) == "route fd99::1/48 has host bits set")
      assert(Protocol::Request.parse(route_json(route: "10.99.0.1/32")).is_a?(Protocol::AddRoute))
      assert(Protocol::Request.parse(route_json(route: "0.0.0.0/0")).is_a?(Protocol::AddRoute))
    end

    test "applies the rules of Address.new" do
      line = create_json(addresses: %([{"address": "10.77.0.2", "prefix": 24}]))
      assert(parse_error(line) == "An IPv4 address needs a peer")
      line = create_json(addresses: %([{"address": "10.77.0.2", "prefix": 33, "peer": "10.77.0.1"}]))
      assert(parse_error(line) == "Prefix length 33 outside 0..32")
      line = create_json(addresses: %([{"address": "fd77::2", "prefix": 64, "peer": "fd77::1"}]))
      assert(parse_error(line) == "An IPv6 address takes no peer, got fd77::1")
      line = create_json(addresses: %([{"address": "10.77.0.2", "prefix": 24, "peer": "fd77::1"}]))
      assert(parse_error(line) == "The peer fd77::1 is not an IPv4 address")
    end

    test "rejects a create that lists one local address twice" do
      twice = %([{"address": "10.77.0.2", "prefix": 24, "peer": "10.77.0.1"}, {"address": "10.77.0.2", "prefix": 25, "peer": "10.77.0.9"}])
      error = raised(Protocol::Error) { Protocol::Request.parse(create_json(addresses: twice)) }
      assert(error.message == "address 10.77.0.2 listed twice")
      assert(error.field! == "addresses")
      v6 = %([{"address": "fd77::1", "prefix": 64}, {"address": "FD77::0:1", "prefix": 48}])
      assert(parse_error(create_json(addresses: v6)) == "address fd77::1 listed twice")
    end

    test "rejects more than 16 addresses or 64 routes in a create" do
      addresses = (1..17).map { |i| %({"address": "fd77::#{i}", "prefix": 64}) }.join(",")
      assert(parse_error(create_json(addresses: "[#{addresses}]")) == "too many addresses: 17, at most 16")
      routes = (0..64).map { |i| %("10.#{i}.0.0/16") }.join(",")
      assert(parse_error(create_json(routes: "[#{routes}]")) == "too many routes: 65, at most 64")
      sixteen = (1..16).map { |i| %({"address": "fd77::#{i}", "prefix": 64}) }.join(",")
      assert(Protocol::Request.parse(create_json(addresses: "[#{sixteen}]")).is_a?(Protocol::Create))
    end

    test "rejects an oversized line" do
      assert(parse_error(" " * (Protocol::MAX_REQUEST + 1)) == "request longer than #{Protocol::MAX_REQUEST} bytes")
    end

    test "rejects fields of the wrong type without raising anything else" do
      assert(parse_error(create_json(mtu: %("x"))) == "field mtu must be an integer")
      assert(parse_error(create_json(mtu: "1280.5")) == "field mtu must be an integer")
      assert(parse_error(create_json(mtu: "null")) == "field mtu must be an integer")
      assert(parse_error(create_json(name: "5")) == "field name must be a string or null")
      assert(parse_error(create_json(addresses: "{}")) == "field addresses must be an array")
      assert(parse_error(create_json(routes: %("10.0.0.0/8"))) == "field routes must be an array")
      assert(parse_error(create_json(routes: "[5]")) == "route must be a string")
      assert(parse_error(create_json(addresses: "[5]")) == "address must be a JSON object")
      line = create_json(addresses: %([{"address": 5, "prefix": 24, "peer": "10.77.0.1"}]))
      assert(parse_error(line) == "field address must be a string")
      line = create_json(addresses: %([{"address": "10.77.0.2", "prefix": "24", "peer": "10.77.0.1"}]))
      assert(parse_error(line) == "field prefix must be an integer")
      line = create_json(addresses: %([{"address": "10.77.0.2", "prefix": 24, "peer": 5}]))
      assert(parse_error(line) == "field peer must be a string or null")
      assert(parse_error(address_json(address: %("fd77::2"))) == "address must be a JSON object")
      assert(parse_error(%({"version": 1, "op": "add_route", "name": "utun7", "route": [1]})) == "field route must be a string")
    end

    test "rejects missing fields" do
      assert(parse_error(%({"version": 1, "op": "add_route", "route": "10.0.0.0/8"})) == "missing field name")
      assert(parse_error(%({"version": 1, "op": "add_route", "name": "utun7"})) == "missing field route")
      assert(parse_error(%({"version": 1, "op": "create", "addresses": [], "routes": []})) == "missing field mtu")
      assert(parse_error(%({"version": 1, "op": "create", "mtu": 1500, "routes": []})) == "missing field addresses")
      line = create_json(addresses: %([{"prefix": 24}]))
      assert(parse_error(line) == "missing field address")
    end

    test "an error about a field names it in field" do
      missing = raised(Protocol::Error) { Protocol::Request.parse(route_json.sub(%(, "route": "10.99.0.0/16"), "")) }
      mistyped = raised(Protocol::Error) { Protocol::Request.parse(create_json(mtu: %("big"))) }
      unknown = raised(Protocol::Error) { Protocol::Request.parse(create_json(extra: %(, "evil": 1))) }

      assert(missing.field == "route")
      assert(mistyped.field == "mtu")
      assert(unknown.field == "evil")
      assert(unknown.field! == "evil")
    end

    test "an error about the value of a field names it in field" do
      cases = {
        "mtu"       => create_json(mtu: "10"),
        "addresses" => create_json(addresses: "[#{([%({"address": "fd77::2", "prefix": 64})] * 17).join(",")}]"),
        "routes"    => create_json(routes: %(["10.0.0.0/8", 5])),
        "name"      => create_json(name: %("eth0")),
        "address"   => create_json(addresses: %([{"address": "nope", "prefix": 64}])),
        "peer"      => create_json(addresses: %([{"address": "fd77::2", "prefix": 64, "peer": "nope"}])),
        "version"   => %({"version": 2, "op": "add_route"}),
      }
      cases.each do |field, line|
        assert(raised(Protocol::Error) { Protocol::Request.parse(line) }.field == field)
      end

      too_long = address_json(address: %({"address": "fd77::2", "prefix": 129}))
      lonely = address_json(address: %({"address": "10.77.0.2", "prefix": 24}))
      extra = address_json(address: %({"address": "fd77::2", "prefix": 64, "peer": "fd77::1"}))
      assert(raised(Protocol::Error) { Protocol::Request.parse(too_long) }.field == "prefix")
      assert(raised(Protocol::Error) { Protocol::Request.parse(lonely) }.field == "peer")
      assert(raised(Protocol::Error) { Protocol::Request.parse(extra) }.field == "peer")
      assert(raised(Protocol::Error) { Protocol::Request.parse(create_json(routes: %(["10.0.0.1/8"]))) }.field == "routes")
      assert(raised(Protocol::Error) { Protocol::Request.parse(route_json(route: "nope")) }.field == "route")
      assert(raised(Protocol::Error) { Protocol::Request.parse(route_json(route: "10.0.0.1/8")) }.field == "route")
    end

    test "Create#name! returns the name and raises when there is none" do
      named = Tunnelgeist::Protocol::Create.new(name: Tunnelgeist::InterfaceName.new("utun5"), mtu: 1_280, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix)
      unnamed = Tunnelgeist::Protocol::Create.new(name: nil, mtu: 1_280, addresses: [] of Tunnelgeist::Address, routes: [] of Tunnelgeist::Prefix)

      assert(named.name! == Tunnelgeist::InterfaceName.new("utun5"))
      raised(NilAssertionError) { unnamed.name! }
    end

    test "Reply#name! and #error! return the value and raise when there is none" do
      full = Tunnelgeist::Protocol::Reply.new(ok: false, name: UTUN7, error: "boom")
      empty = Tunnelgeist::Protocol::Reply.new(ok: true)

      assert(full.name! == UTUN7)
      assert(full.error! == "boom")
      raised(NilAssertionError) { empty.name! }
      raised(NilAssertionError) { empty.error! }
    end

    test "an error about no single field has no field" do
      error = raised(Protocol::Error) { Protocol::Request.parse("[1]") }

      assert(error.field.nil?)
      assert(raised(NilAssertionError) { error.field! }.message.to_s.includes?("request must be a JSON object"))
    end

    test "rejects unknown extra fields by name" do
      assert(parse_error(create_json(extra: %(, "evil": 1))) == %(unknown field "evil"))
      assert(parse_error(route_json(extra: %(, "address": "10.0.0.1"))) == %(unknown field "address"))
      line = create_json(addresses: %([{"address": "fd77::2", "prefix": 64, "mask": 1}]))
      assert(parse_error(line) == %(unknown field "mask"))
    end

    test "survives nested garbage" do
      assert(parse_error("[" * 1_000).starts_with?("malformed JSON"))
      assert(parse_error(create_json(extra: %(, "x": {"y": [[[]]]}))) == %(unknown field "x"))
      assert(parse_error(%({"version": {"a": []}, "op": []})) == "field version must be an integer")
    end

    test "Reply omits null fields" do
      assert(Protocol::Reply.new(ok: true).to_json == %({"ok":true}))
      assert(Protocol::Reply.new(ok: false, error: "boom").to_json == %({"ok":false,"error":"boom"}))
      assert(Protocol::Reply.new(ok: true, name: UTUN7).to_json == %({"ok":true,"name":"utun7"}))
    end

    test "Reply parses what it writes" do
      replies = [
        Protocol::Reply.new(ok: true),
        Protocol::Reply.new(ok: true, name: UTUN7),
        Protocol::Reply.new(ok: false, error: "unknown device"),
      ]
      replies.each { |reply| assert(Protocol::Reply.parse(reply.to_json) == reply) }
    end

    test "Reply.parse raises Protocol::Error for bad input" do
      assert(raised(Protocol::Error) { Protocol::Reply.parse("{") }.message.to_s.starts_with?("malformed JSON"))
      assert(raised(Protocol::Error) { Protocol::Reply.parse(%({"ok": "yes"})) }.message == "field ok must be a boolean")
      assert(raised(Protocol::Error) { Protocol::Reply.parse(%({"ok": null})) }.message == "field ok must be a boolean")
      assert(raised(Protocol::Error) { Protocol::Reply.parse(%({"ok": true, "extra": 1})) }.message == %(unknown field "extra"))
      assert(raised(Protocol::Error) { Protocol::Reply.parse(%({"name": "x"})) }.message == "missing field ok")
      assert(raised(Protocol::Error) { Protocol::Reply.parse(%({"ok": true, "name": 5})) }.message == "field name must be a string or null")
      assert(raised(Protocol::Error) { Protocol::Reply.parse(%({"ok": true, "name": "en0"})) }.field! == "name")
    end
  {% end %}
end
