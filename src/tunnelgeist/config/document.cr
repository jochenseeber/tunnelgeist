{% skip_file unless flag?(:darwin) %}

require "./document/address_rule"
require "./document/client"
require "./document/element_error"
require "./document/list_converter"
require "./document/main"
require "./document/object_converter"
require "./document/strict_fields"
require "./document/text_converter"
require "./document/unknown_field"
require "./document/value_type"
require "./document/wrong_type"

module Tunnelgeist
  struct Config
    # The shape of the configuration files (CF1 to CF3), read with
    # `JSON::Serializable`: the types, field names and required fields, and
    # no field besides them. A document holds the file's values as they are
    # written; `Loader` checks what they mean and turns them into `Config`.
    #
    # Every value is read through a converter that checks its JSON type
    # first, and an unknown field raises `UnknownField`, so the errors carry
    # what the loader needs to word them itself instead of the reader's
    # texts.
    module Document
    end
  end
end
