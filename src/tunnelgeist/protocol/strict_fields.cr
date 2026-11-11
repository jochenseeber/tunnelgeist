{% skip_file unless flag?(:darwin) %}

require "json"
require "./error"

module Tunnelgeist
  module Protocol
    # :nodoc:
    # Refuses a field the type does not declare, as
    # `JSON::Serializable::Strict` does, but with an `Error` that names the
    # field, the text the daemon has always replied with. Include it after
    # `JSON::Serializable`.
    module StrictFields
      protected def on_unknown_json_attribute(pull : JSON::PullParser, key : String, key_location) : Nil
        raise Error.new("unknown field #{key.inspect}", field: key)
      end
    end
  end
end
