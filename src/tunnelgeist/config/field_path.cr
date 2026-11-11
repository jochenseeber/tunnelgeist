{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  struct Config
    # Builds the field paths errors name, such as
    # `clients[0].addresses[1].peer`.
    module FieldPath
      # The path of the field *name* inside the object at the path *at*, or
      # just *name* at the top of a file (*at* nil). A name that is not
      # plain, such as an unknown key of the file, is quoted with its
      # control characters escaped, so it cannot break the error's line or
      # pass escape sequences to a terminal.
      def self.child(at : String?, name : String) : String
        segment = plain?(name) ? name : name.inspect
        at ? "#{at}.#{segment}" : segment
      end

      # Whether *name* goes into a path as it is: an ASCII letter or `_`,
      # then ASCII letters, digits and `_`. Any other name is quoted.
      private def self.plain?(name : String) : Bool
        first = name[0]?
        return false unless first && (first.ascii_letter? || first == '_')

        name.each_char.all? { |char| char.ascii_alphanumeric? || char == '_' }
      end

      # The path of the element at *index* of the array at the path *at*.
      def self.element(at : String?, index : Int32) : String
        "#{at}[#{index}]"
      end
    end
  end
end
