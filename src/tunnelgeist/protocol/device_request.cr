{% skip_file unless flag?(:darwin) %}

require "json"
require "../interface_name"
require "../key"
require "./request"
require "./text_converter"

module Tunnelgeist
  module Protocol
    # A request on an existing device, which names it and proves
    # possession of its key.
    abstract struct DeviceRequest < Request
      # The device the request is about; the daemon refuses a name it does not
      # know.
      @[JSON::Field(converter: Tunnelgeist::Protocol::TextConverter(Tunnelgeist::InterfaceName).new("name"))]
      getter name : InterfaceName
      # The key `create` returned, which proves the sender created the device;
      # without it the daemon refuses the change.
      @[JSON::Field(converter: Tunnelgeist::Protocol::TextConverter(Tunnelgeist::Key).new("key"))]
      getter key : Key

      # The key never reaches a log line or `pp` output (UC5), so the
      # default `inspect` and `to_s` of a struct are replaced.
      def inspect(io : IO) : Nil
        io << "#<" << self.class.name << " name=" << name.to_s.inspect << " key=[REDACTED] "
        inspect_subject(io)
        io << ">"
      end

      # Same as `inspect`.
      def to_s(io : IO) : Nil
        inspect(io)
      end

      # Writes the address or route of the request for `inspect`.
      protected abstract def inspect_subject(io : IO) : Nil
    end
  end
end
