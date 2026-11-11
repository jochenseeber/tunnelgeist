{% skip_file unless flag?(:darwin) %}

require "json"
require "./value_type"
require "./wrong_type"

module Tunnelgeist
  struct Config
    module Document
      # The `JSON::Field` converter of an object read as the document type
      # `T`, and the reader of a whole file. A value that is not an object
      # raises `WrongType`.
      struct ObjectConverter(T)
        # The `T` read from the object *pull* is at.
        def from_json(pull : JSON::PullParser) : T
          raise WrongType.new(ValueType::Object, pull: pull) unless pull.kind.begin_object?
          T.new(pull)
        end
      end
    end
  end
end
