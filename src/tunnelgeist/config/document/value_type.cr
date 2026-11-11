{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  struct Config
    module Document
      # The JSON types a configuration value can be required to have.
      enum ValueType
        String
        Array
        Object

        # The type with its article, as an error names it: `a string`.
        def phrase : ::String
          string? ? "a string" : "an #{to_s.downcase}"
        end
      end
    end
  end
end
