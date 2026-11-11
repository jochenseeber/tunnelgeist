{% skip_file unless flag?(:darwin) %}

require "json"
require "./value_type"
require "./wrong_type"

module Tunnelgeist
  struct Config
    module Document
      # The `JSON::Field` converter of a string. Anything else, null included
      # unless `JSON::Serializable` reads the null of a nilable field itself,
      # raises `WrongType`.
      struct TextConverter
        # The converter; *nullable* says whether the field may be null, for
        # the error text only.
        def initialize(*, @nullable : Bool = false)
        end

        # The string *pull* is at.
        def from_json(pull : JSON::PullParser) : String
          raise WrongType.new(ValueType::String, nullable: @nullable, pull: pull) unless pull.kind.string?
          pull.read_string
        end
      end
    end
  end
end
