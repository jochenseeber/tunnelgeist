{% skip_file unless flag?(:darwin) %}

require "./document/address"
require "./document/op"
require "./document/outcome"
require "./document/version"

module Tunnelgeist
  module Protocol
    # :nodoc:
    # Wire shapes read or written with `JSON::Serializable` that are not
    # messages of their own: the address object, and the fields a reader
    # checks before it reads the whole message, so that a request of
    # another version gets "unsupported version" whatever else it holds.
    module Document
    end
  end
end
