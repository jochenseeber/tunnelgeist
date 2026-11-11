{% skip_file unless flag?(:darwin) %}

require "json"
require "../interface_name"
require "./request"
require "./text_converter"

module Tunnelgeist
  module Protocol
    # A request that changes an existing device. It names the device, and
    # its line carries the device's descriptor, which proves that the sender
    # holds the device (RF1.1, RF1.4).
    abstract struct DeviceRequest < Request
      # The device the request is about; the daemon refuses a name it does not
      # know and a descriptor of another device.
      @[JSON::Field(converter: Tunnelgeist::Protocol::TextConverter(Tunnelgeist::InterfaceName).new("name"))]
      getter name : InterfaceName
    end
  end
end
