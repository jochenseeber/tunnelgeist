{% skip_file unless flag?(:darwin) %}

require "json"
require "./unknown_field"

module Tunnelgeist
  struct Config
    module Document
      # Refuses a field the type does not declare, as
      # `JSON::Serializable::Strict` does, but with an `UnknownField` that
      # carries the name, so the loader words the error itself. Include it
      # after `JSON::Serializable::Strict`, whose method it overrides.
      module StrictFields
        protected def on_unknown_json_attribute(pull : JSON::PullParser, key : String, key_location) : Nil
          line, column = key_location
          raise UnknownField.new(key, line: line, column: column)
        end
      end
    end
  end
end
