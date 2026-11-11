{% skip_file unless flag?(:darwin) %}

require "./protocol/add_address"
require "./protocol/add_route"
require "./protocol/address_converter"
require "./protocol/address_request"
require "./protocol/boolean_converter"
require "./protocol/common"
require "./protocol/create"
require "./protocol/device_request"
require "./protocol/document"
require "./protocol/error"
require "./protocol/integer_converter"
require "./protocol/list_converter"
require "./protocol/operation"
require "./protocol/remove_address"
require "./protocol/remove_route"
require "./protocol/reply"
require "./protocol/request"
require "./protocol/route_request"
require "./protocol/strict_fields"
require "./protocol/syntax_check"
require "./protocol/text_converter"

module Tunnelgeist
  # The JSON-lines protocol between the client library and the root
  # daemon `tunnelgeist` (UP1 to UP5), read and written with
  # `JSON::Serializable`. The daemon parses untrusted input as root, so
  # every field has a converter that checks its type, unknown fields are
  # rejected, and `Request.parse` raises nothing but `Error`.
  module Protocol
  end
end
