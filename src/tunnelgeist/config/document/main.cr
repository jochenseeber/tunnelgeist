{% skip_file unless flag?(:darwin) %}

require "json"
require "./client"
require "./list_converter"
require "./object_converter"
require "./strict_fields"
require "./text_converter"

module Tunnelgeist
  struct Config
    module Document
      # The main file as it is written (CF1). `includes` and `clients` are
      # empty when the file leaves them out or writes null.
      struct Main
        include JSON::Serializable
        include JSON::Serializable::Strict
        include StrictFields

        # The path of the daemon's socket.
        @[JSON::Field(converter: TextConverter.new)]
        getter socket : String
        # The main group.
        @[JSON::Field(converter: TextConverter.new)]
        getter group : String
        # Paths and globs of included client files.
        @[JSON::Field(converter: ListConverter.new(TextConverter.new))]
        getter includes : Array(String) = [] of String
        # The inline client configurations.
        @[JSON::Field(converter: ListConverter.new(ObjectConverter(Client).new))]
        getter clients : Array(Client) = [] of Client
      end
    end
  end
end
