{% skip_file unless flag?(:darwin) %}

require "./decimal"

module Tunnelgeist
  # The name of a utun interface: `utun` and a unit number without leading
  # zeros, as the kernel writes them. Every name the library and the daemon
  # pass around has been checked once, where it came in.
  struct InterfaceName
    # The unit number N of `utunN`.
    getter unit : UInt32

    @text : String

    # The name *text*, or nil when it has another form or a unit the kernel
    # cannot address: `sc_unit` is N + 1, so N must stay under
    # `UInt32::MAX`.
    def self.parse?(text : String) : InterfaceName?
      return unless text.starts_with?("utun")

      unit_text = text[4..]
      return unless Decimal.canonical?(unit_text)

      number = unit_text.to_u32?
      return unless number && number < UInt32::MAX

      new(checked: text, unit: number)
    end

    # The name *text*; raises `ArgumentError` when `parse?` refuses it.
    def self.new(text : String) : InterfaceName
      parse?(text) || raise ArgumentError.new("name must be utun and a unit number, such as utun7, got #{text.inspect}")
    end

    private def initialize(*, checked @text : String, @unit : UInt32)
    end

    def_equals_and_hash @text

    # The name as the kernel writes it, such as `utun7`.
    def to_s(io : IO) : Nil
      io << @text
    end
  end
end
