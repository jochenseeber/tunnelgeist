{% skip_file unless flag?(:darwin) %}

require "json"
require "./address_rule"
require "./list_converter"
require "./object_converter"
require "./strict_fields"
require "./text_converter"

module Tunnelgeist
  struct Config
    module Document
      # A client configuration as the file has it (CF2): an inline entry of
      # the main file's `clients`, or the whole of an included file. `users`,
      # `groups` and `signatures` are nil when the file leaves them out or
      # writes null, and an empty list when the file lists none, which
      # `Config::Client` tells apart; `addresses` and `routes` are empty
      # either way.
      struct Client
        include JSON::Serializable
        include JSON::Serializable::Strict
        include StrictFields

        # The configuration's name.
        @[JSON::Field(converter: TextConverter.new)]
        getter name : String
        # User names and numeric uids, each a string.
        @[JSON::Field(converter: ListConverter.new(TextConverter.new))]
        getter users : Array(String)?
        # Group names.
        @[JSON::Field(converter: ListConverter.new(TextConverter.new))]
        getter groups : Array(String)?
        # Code requirements.
        @[JSON::Field(converter: ListConverter.new(TextConverter.new))]
        getter signatures : Array(String)?
        # The address rules.
        @[JSON::Field(converter: ListConverter.new(ObjectConverter(AddressRule).new))]
        getter addresses : Array(AddressRule) = [] of AddressRule
        # Route destinations in CIDR notation.
        @[JSON::Field(converter: ListConverter.new(TextConverter.new))]
        getter routes : Array(String) = [] of String

        # The users; raises `NilAssertionError` when the file lists none.
        def users! : Array(String)
          users || raise NilAssertionError.new("client #{name} lists no users")
        end

        # The groups; raises `NilAssertionError` when the file lists none.
        def groups! : Array(String)
          groups || raise NilAssertionError.new("client #{name} lists no groups")
        end

        # The signatures; raises `NilAssertionError` when the file lists none.
        def signatures! : Array(String)
          signatures || raise NilAssertionError.new("client #{name} lists no signatures")
        end
      end
    end
  end
end
