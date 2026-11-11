{% skip_file unless flag?(:darwin) %}

require "json"
require "socket"
require "system/user"
require "../decimal"
require "../lib_system"
require "../membership"
require "../prefix"
require "../signature_policy"
require "./address_rule"
require "./client"
require "./document"
require "./document/value_type"
require "./document/wrong_type"
require "./error"
require "./field_path"
require "./location"
require "./syntax_check"
require "./directory"
require "./directory/missing"
require "./trusted_directory"
require "./trusted_file"
require "../config"

module Tunnelgeist
  struct Config
    # Reads and validates a configuration (CA1): the main file and the files
    # its includes name, each opened and checked through every directory
    # from `/` down by a `Directory`, `TrustedDirectory` unless the caller
    # gives another (RF5), and read from what was checked, then read into its `Document` type, which refuses unknown
    # fields (CC1), and checked and turned into `Config`. Loading builds a
    # new `Config` and changes nothing else, so a failure leaves whatever
    # the caller holds untouched.
    #
    # An error in a file's syntax or shape, which `SyntaxCheck` or the JSON
    # reader finds, names the line and column and the field path; one the
    # loader's checks find names the field path only.
    #
    # A relative main path is taken relative to the working directory. A
    # relative include entry is opened from the main file's checked
    # directory, an absolute one walks from `/`; a `..` component is refused
    # in either, and in the main path, since the walk only goes down. Only
    # the last path component of an entry may hold glob characters (`*`,
    # `?`, `[`); it is matched against the names in its checked directory,
    # so glob characters in the directory names never count, and hidden
    # names match only a pattern that starts with a dot.
    class Loader
      # How `JSON::Serializable` starts the error about a missing field, the
      # one error of its own the loader words in its terms.
      MISSING_FIELD = "Missing JSON attribute: "
      # Why a path with a `..` component is refused.
      PARENT_COMPONENT = "must not contain a .. component"

      # Loads the main file at *path*. Every file must be owned by *owner*,
      # every directory above one by root or *owner*.
      # *find_user* returns the uid of a user name, nil for an unknown one;
      # *build_membership* resolves a group and *build_policy* compiles
      # signature requirements, each raising `ArgumentError` for what it
      # cannot. Anything else the two lookups raise, such as the
      # `RuntimeError` of a failing directory service, is taken as a failed
      # lookup of that field. *open_directory* opens the checked directory
      # reached from `/` through the path components it is given, for the
      # trusted owner it is given; the caller closes it.
      def initialize(*, @path : String, @owner : UInt32 = LibSystem.geteuid,
                     @find_user : String -> UInt32? = ->(name : String) : UInt32? {
                       System::User.find_by?(name: name).try(&.id.to_u32)
                     },
                     @build_membership : String -> Membership = ->(name : String) { Membership.new(name) },
                     @build_policy : Array(String) -> SignaturePolicy = ->(requirements : Array(String)) {
                       SignaturePolicy.new(requirements)
                     },
                     @open_directory : Array(String), UInt32 -> Directory = ->(names : Array(String), owner : UInt32) {
                       TrustedDirectory.open(names, owner: owner).as(Directory)
                     })
        @file = Loader.absolute(@path)
      end

      # *path* from `/`, relative to the working directory when it is
      # relative, without empty and `.` components.
      protected def self.absolute(path : String) : String
        full = path.starts_with?('/') ? path : "#{Dir.current}/#{path}"
        "/#{names(full).join('/')}"
      end

      # The components of *path*, without empty and `.` ones.
      protected def self.names(path : String) : Array(String)
        path.split('/').reject! { |name| name.empty? || name == "." }
      end

      # The configuration; raises `Config::Error` naming the file, and the
      # field when there is one, for the first problem found. A directory
      # the walk refuses is named itself; a missing one makes the main file
      # missing.
      def load : Config
        names = Loader.names(@file)
        raise Error.new(PARENT_COMPONENT, file: @file) if names.includes?("..")
        name = names.pop? || raise Error.new("must be a regular file", file: @file)

        opening(names) do |directory|
          main = parse(Document::Main, source: directory.read(name))
          socket = main.socket
          check_socket(socket)
          group = main.group
          membership = looking_up(file: @file, field: "group") { @build_membership.call(group) }
          included = resolve(main.includes, directory: directory)

          clients_by_name = {} of String => String
          clients = main.clients.map_with_index do |document, index|
            build_client(document, file: @file, at: FieldPath.element("clients", index), names: clients_by_name)
          end
          included.each do |source|
            clients << build_client(parse(Document::Client, source: source), file: source.path, at: nil,
              names: clients_by_name)
          end
          raise Error.new("no client configuration in the file or its includes", file: @file) if clients.empty?

          Config.new(socket: socket, group: membership.name, membership: membership, clients: clients)
        end
      rescue error : Directory::Missing
        # The includes name what they miss themselves, so this is the main
        # file or a directory above it, and the path given is what to fix.
        raise Error.new("does not exist", file: @file, cause: error)
      end

      # Runs the block with the directory `open_directory` opens through
      # *names* and closes it afterwards.
      private def opening(names : Array(String), &)
        directory = @open_directory.call(names, @owner)
        begin
          yield directory
        ensure
          directory.close
        end
      end

      # Refuses a *socket* path no client could find or the daemon could not
      # bind: it must be absolute, hold no NUL byte and fit a Unix socket
      # address, which `Socket::UNIXAddress` checks as binding it does.
      # Checked at load, so `install` refuses it before it touches the
      # working daemon.
      private def check_socket(socket : String) : Nil
        raise Error.new("socket must be an absolute path", file: @file, field: "socket") unless socket.starts_with?('/')
        raise Error.new("socket contains a NUL byte", file: @file, field: "socket") if socket.includes?('\0')

        building(file: @file, field: "socket") { Socket::UNIXAddress.new(socket) }
      end

      # The *document* type read from *source*, after `SyntaxCheck` has
      # passed it and its text is valid UTF-8.
      private def parse(document : T.class, *, source : TrustedFile) : T forall T
        text = source.text
        file = source.path
        # The lexer passes any bytes through in strings, and the checks of
        # names and paths raise on them.
        raise Error.new("not valid UTF-8", file: file) unless text.valid_encoding?
        SyntaxCheck.check(text, file: file)
        pull = JSON::PullParser.new(text)
        unless pull.kind.begin_object?
          # Before it reads past the first token the pull parser has no
          # position, so it would place a scalar at 0:0; the text has it.
          start = Location.start_of(text)
          raise Document::WrongType.new(Document::ValueType::Object, line: start.line, column: start.column)
        end
        Document::ObjectConverter(T).new.from_json(pull)
      rescue error : JSON::ParseException
        raise shape_error(error, file: source.path)
      end

      # *error* of the reader of a document of *file* as a `Config::Error`
      # about the field it names. The reader wraps the error of a nested
      # value in one about its field, `Document::ListConverter` adds the
      # element of an array and `Document::StrictFields` the unknown field,
      # so the chain of causes, outermost first, is the field path, and its
      # innermost error says why.
      private def shape_error(error : JSON::ParseException, *, file : String) : Error
        field = nil
        innermost = error
        current = error.as(Exception?)
        while current.is_a?(JSON::ParseException)
          innermost = current
          case current
          when Document::ElementError
            field = FieldPath.element(field, current.index)
          when Document::UnknownField
            field = FieldPath.child(field, current.key)
          when JSON::SerializableError
            current.attribute.try { |name| field = FieldPath.child(field, name) }
          end
          current = current.cause
        end

        Error.new(reason(innermost), file: file, field: field, location: Location.of(innermost), cause: error)
      end

      # Why the reader refused a value, in the loader's terms where it knows
      # the error. Any other keeps the reader's text, without the location
      # `JSON::ParseException` appends and the `parsing TYPE#FIELD` lines
      # `JSON::SerializableError` adds, which the loader names itself.
      private def reason(error : JSON::ParseException) : String
        case error
        when Document::UnknownField
          "unknown field #{error.key.inspect}"
        when Document::WrongType
          error.reason
        else
          missing = missing_field(error)
          missing ? "missing field #{missing}" : reader_text(error)
        end
      end

      # The field *error* says is missing; nil for any other error.
      private def missing_field(error : JSON::ParseException) : String?
        return unless error.is_a?(JSON::SerializableError) && error.cause.nil?
        return unless error.message.to_s.starts_with?(MISSING_FIELD)

        error.attribute
      end

      private def reader_text(error : JSON::ParseException) : String
        first = error.message.to_s.lines.first? || ""
        first.rchop(" at line #{error.line_number}, column #{error.column_number}")
      end

      # The files *includes* names, relative to the main file's checked
      # *directory*, in order; the files of a glob sorted by name.
      private def resolve(includes : Array(String), *, directory : Directory) : Array(TrustedFile)
        files = [] of TrustedFile
        includes.each_with_index do |entry, index|
          files.concat(resolve_entry(entry, directory: directory, field: FieldPath.element("includes", index)))
        end
        files
      end

      # The files the include *entry* names, read through *directory* when
      # it is relative and from `/` when it is absolute. Errors about the
      # entry itself are about *field* of the main file, a NUL byte
      # included; those about what the walk opens name its path.
      private def resolve_entry(entry : String, *, directory : Directory, field : String) : Array(TrustedFile)
        entry.check_no_null_byte
        names = Loader.names(entry)
        last = names.pop? || raise Error.new("must name a file", file: @file, field: field)
        if names.any? { |name| glob?(name) }
          raise Error.new("glob characters are allowed only in the last path component", file: @file, field: field)
        elsif names.includes?("..") || last == ".."
          raise Error.new(PARENT_COMPONENT, file: @file, field: field)
        end

        begin
          if entry.starts_with?('/')
            opening(names) { |parent| read_entry(parent, name: last) }
          else
            directory.descend(names) { |parent| read_entry(parent, name: last) }
          end
        rescue error : Directory::Missing
          # A glob in a directory that is not there matches nothing.
          raise Error.new("file #{included_path(entry, directory: directory)} does not exist", file: @file,
            field: field, cause: error) unless glob?(last)
          [] of TrustedFile
        end
      rescue error : ArgumentError
        raise Error.new(error.message.to_s, file: @file, field: field, cause: error)
      end

      # The file *name* in *parent*, or the files there whose names match
      # the glob *name*, sorted by name. A hidden name matches only a
      # pattern that starts with a dot, as in a shell.
      private def read_entry(parent : Directory, *, name : String) : Array(TrustedFile)
        if glob?(name)
          hidden = name.starts_with?('.')
          matches = parent.names.select! { |child| (hidden || !child.starts_with?('.')) && File.match?(name, child) }
          matches.sort!.compact_map { |child| read_match(parent, name: child) }
        else
          [parent.read(name)]
        end
      end

      # The file *name* a glob matched in *parent*; nil when it went away
      # since the directory was listed, as if it had been listed after.
      private def read_match(parent : Directory, *, name : String) : TrustedFile?
        parent.read(name)
      rescue Directory::Missing
        nil
      end

      # The path the include *entry* names, for the error that it does not
      # exist.
      private def included_path(entry : String, *, directory : Directory) : String
        entry.starts_with?('/') ? Loader.absolute(entry) : Loader.absolute("#{directory.path}/#{entry}")
      end

      # Whether the include path part *text* is a glob: it holds `*`, `?`
      # or `[`.
      private def glob?(text : String) : Bool
        text.each_char.any?(&.in?('*', '?', '['))
      end

      # Whether *name* is a valid client name: an ASCII letter or digit, then
      # ASCII letters, digits, `.`, `_` and `-`. The name ends up in
      # `name=reason` pairs of log lines.
      private def client_name?(name : String) : Bool
        first = name[0]?
        return false unless first && first.ascii_alphanumeric?

        name.each_char.all? { |char| char.ascii_alphanumeric? || char.in?('.', '_', '-') }
      end

      # The client configuration of *document* from *file*, at the field path
      # *at* (nil for an included file, which holds just the one object).
      # *names* maps each name seen so far to its file, and gains this one.
      private def build_client(document : Document::Client, *, file : String, at : String?,
                               names : Hash(String, String)) : Client
        name = document.name
        unless client_name?(name)
          raise Error.new(%(invalid client name #{name.inspect}: must be a letter or digit followed by letters, ) +
                          %(digits, ".", "_" or "-"), file: file, field: FieldPath.child(at, "name"))
        end
        previous = names[name]?
        if previous
          raise Error.new("duplicate client name #{name.inspect}, also in #{previous}", file: file,
            field: FieldPath.child(at, "name"))
        end
        names[name] = file

        users = document.users.try { |entries| parse_users(entries, file: file, at: FieldPath.child(at, "users")) }
        groups = document.groups.try do |entries|
          entries.map_with_index do |entry, index|
            looking_up(file: file, field: FieldPath.element(FieldPath.child(at, "groups"), index)) { @build_membership.call(entry) }
          end
        end
        policy = document.signatures.try do |requirements|
          building(file: file, field: FieldPath.child(at, "signatures")) { @build_policy.call(requirements) }
        end
        addresses = document.addresses.map_with_index do |rule, index|
          build_rule(rule, file: file, at: FieldPath.element(FieldPath.child(at, "addresses"), index))
        end
        routes = document.routes.map_with_index do |text, index|
          parse_route(text, file: file, field: FieldPath.element(FieldPath.child(at, "routes"), index))
        end

        Client.new(name: name, users: users, groups: groups, policy: policy, addresses: addresses, routes: routes)
      end

      # The uids of the `users` *entries*: an entry of ASCII digits is a uid,
      # any other a user name `find_user` must know.
      private def parse_users(entries : Array(String), *, file : String, at : String) : Array(UInt32)
        entries.map_with_index do |entry, index|
          field = FieldPath.element(at, index)
          if Decimal.digits?(entry)
            entry.to_u32? || raise Error.new("uid #{entry} out of range", file: file, field: field)
          else
            uid = looking_up(file: file, field: field) { @find_user.call(entry) }
            uid || raise Error.new("unknown user #{entry.inspect}", file: file, field: field)
          end
        end
      end

      # The address rule of *document* at the field path *at*. A peer is
      # refused where it could never be checked: on an IPv6 rule, or of the
      # other family on an IPv4 rule.
      private def build_rule(document : Document::AddressRule, *, file : String, at : String) : AddressRule
        network = parse_prefix(document.network, file: file, field: "#{at}.network")
        peer = document.peer.try { |text| parse_prefix(text, file: file, field: "#{at}.peer") }
        if peer
          raise Error.new("an IPv6 rule takes no peer", file: file, field: "#{at}.peer") if network.family.inet6?
          raise Error.new("peer #{peer} is not an IPv4 prefix", file: file, field: "#{at}.peer") unless peer.family.inet?
        end

        AddressRule.new(network: network, peer: peer)
      end

      # The route destination *text*, which must have no host bits set, as
      # the protocol requires of a requested route.
      private def parse_route(text : String, *, file : String, field : String) : Prefix
        route = parse_prefix(text, file: file, field: field)
        raise Error.new("route #{text} has host bits set", file: file, field: field) if route.host_bits?
        route
      end

      private def parse_prefix(text : String, *, file : String, field : String) : Prefix
        building(file: file, field: field) { Prefix.parse(text) }
      end

      # The value of the block; an `ArgumentError` it raises becomes a
      # `Config::Error` about *field* of *file* with the same message.
      private def building(*, file : String, field : String, &)
        yield
      rescue error : ArgumentError
        raise Error.new(error.message.to_s, file: file, field: field, cause: error)
      end

      # The value of the user or group lookup in the block, as `building`
      # has it; any other exception becomes a `Config::Error` about *field*
      # of *file* too, so that `load` raises nothing else when the
      # directory service fails.
      private def looking_up(*, file : String, field : String, &)
        building(file: file, field: field) { yield }
      rescue error : Error
        raise error
      rescue error : Exception
        raise Error.new("lookup failed: #{error.message}", file: file, field: field, cause: error)
      end
    end
  end
end
