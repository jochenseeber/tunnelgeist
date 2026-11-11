{% skip_file unless flag?(:darwin) %}

module Tunnelgeist
  module Commands
    # The verb of a `route` invocation.
    private enum RouteVerb
      Add
      Delete

      # The verb as `route` takes it on its command line.
      def word : String
        to_s.downcase
      end
    end
  end
end
