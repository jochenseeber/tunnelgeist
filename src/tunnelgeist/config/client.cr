{% skip_file unless flag?(:darwin) %}

require "../membership"
require "../peer"
require "../prefix"
require "../refusal"
require "../signature_policy"
require "../signature_policy/inspection"
require "./address_rule"

module Tunnelgeist
  struct Config
    # One client configuration (CF2): who it applies to and what it allows.
    # `users`, `groups` and `policy` (from `signatures`) are nil when the
    # file leaves the field out, which restricts nothing. A field that is
    # present restricts even when its list is empty: nothing satisfies it,
    # so the configuration admits nobody.
    record Client, name : String, users : Array(UInt32)?, groups : Array(Membership)?, policy : SignaturePolicy?,
      addresses : Array(AddressRule), routes : Array(Prefix) do
      # The refusal of a peer whose uid is not one of `users`.
      USERS = Refusal.new(reason: :users)
      # The refusal of a peer that is a member of none of `groups`.
      GROUPS = Refusal.new(reason: :groups)

      # The uids; raises `NilAssertionError` when the file lists no `users`.
      def users! : Array(UInt32)
        users || raise NilAssertionError.new("client #{name} lists no users")
      end

      # The group memberships; raises `NilAssertionError` when the file lists
      # no `groups`.
      def groups! : Array(Membership)
        groups || raise NilAssertionError.new("client #{name} lists no groups")
      end

      # The signature policy; raises `NilAssertionError` when the file lists
      # no signatures.
      def policy! : SignaturePolicy
        policy || raise NilAssertionError.new("client #{name} lists no signatures")
      end

      # Nil when the configuration applies to *peer* (CF4): every kind it
      # lists is met, by any one entry of the kind. Otherwise the refusal of
      # the first kind that fails, in the order users, groups, signatures;
      # for signatures the refusal `SignaturePolicy#check` gives for
      # *inspection*, or `SignaturePolicy::UNMET` for a policy without
      # requirements, which `check` would pass. *inspection* is the peer's,
      # shared with the other configurations; it may be nil only when the
      # configuration lists no signatures, else this raises `ArgumentError`.
      # Raises `IO::Error` as `Membership#member?` does.
      def applies?(peer : Peer, *, inspection : SignaturePolicy::Inspection?) : Refusal?
        uids = users
        memberships = groups
        signatures = policy
        if signatures && inspection.nil?
          raise ArgumentError.new("client #{name} lists signatures, so it needs the peer's inspection")
        end

        if uids && !uids.includes?(peer.uid)
          USERS
        elsif memberships && memberships.none?(&.member?(peer))
          GROUPS
        elsif signatures.nil?
          nil
        elsif signatures.empty?
          SignaturePolicy::UNMET
        else
          # Never nil here, as checked above; refusing keeps a mistake closed.
          inspection ? signatures.check(inspection) : SignaturePolicy::UNMET
        end
      end
    end
  end
end
