{% skip_file unless flag?(:darwin) %}

require "log"
require "socket"
require "./address"
require "./authorizer/admission"
require "./authorizer/denial"
require "./commands"
require "./device"
require "./fd_passing"
require "./interface_name"
require "./key"
require "./protocol"
require "./command_runner"
require "./handler/admitted"
require "./peer"
require "./prefix"
require "./refusal"
require "./registry"

module Tunnelgeist
  # Serves one client connection (UA5, UP1 to UP7): admits the peer, reads
  # one request line, judges its addresses and routes by the client
  # configurations that apply to the peer (CA3), creates a device or changes
  # one, writes one reply and closes the connection. Its collaborators are
  # injected so the specs can replace them.
  #
  # `handle` never raises: the daemon runs it in one fiber per connection
  # and a client error must not stop it. Every failure becomes an error
  # reply and one log line, which never carries a key (UC5).
  class Handler
    # The failed check of a peer outside the main group.
    private GROUP_REFUSED = Refusal.new(reason: :group)
    # The failed check of a peer no client configuration applies to.
    private CONFIG_REFUSED = Refusal.new(reason: :config)

    @refusal : String

    # *admit* answers which client configurations apply to a peer; the
    # daemon passes `Authorizer#admit`. *group* is the main group, named in
    # the refusal. *request_timeout* is how long a client may take to send
    # its request line. *drain_departures* runs after a new device is
    # configured and before it is registered; the daemon passes
    # `DepartureWatcher#drain`, so a departure event about the previous
    # owner of a recycled name cannot remove the new entry.
    def initialize(@registry : Registry, *,
                   @create_device : (InterfaceName?, Int32) -> Device::Utun = ->(name : InterfaceName?, mtu : Int32) { Device.create(name, mtu: mtu) },
                   @run : CommandRunner::Run = CommandRunner.default,
                   @admit : Peer -> Authorizer::Admission,
                   group : String,
                   @interface_index : InterfaceName -> UInt32 = ->(name : InterfaceName) { LibC.if_nametoindex(name.to_s) },
                   @request_timeout : Time::Span = Protocol::REQUEST_TIMEOUT,
                   @drain_departures : -> Nil = -> { },
                   @log : Log)
      @refusal = "not permitted: not in group #{group} or not allowed by a client configuration"
    end

    # Serves the connection on *socket* and closes it.
    def handle(socket : UNIXSocket) : Nil
      socket.write_timeout = @request_timeout
      admitted = permitted_peer(socket)
      return unless admitted

      request = read_request(socket, peer: admitted.peer)
      return unless request

      serve(socket, admitted: admitted, request: request)
    rescue error
      # Only a failure in the handler itself reaches here; keep the daemon
      # alive.
      @log.error { "handler failed: #{error.class}: #{error.message}" }
    ensure
      begin
        socket.close
      rescue error : IO::Error
        @log.warn { "closing the connection failed: #{error.message}" }
      end
    end

    # The peer of *socket* with its admission when at least one client
    # configuration applies to it (UA8, CA2). Otherwise replies the refusal,
    # logs why and returns nil. An admission that cannot be made is a
    # refusal.
    private def permitted_peer(socket : UNIXSocket) : Admitted?
      peer = Peer.of(socket)
      admission = begin
        @admit.call(peer)
      rescue error
        refuse(socket, peer: peer, check: "#{error.class}: #{error.message}")
        return
      end
      if admission.refused?
        refuse(socket, peer: peer, check: refused_check(admission))
        nil
      else
        Admitted.new(peer: peer, admission: admission)
      end
    rescue error
      @log.warn { "refused peer unreadable: #{error.message}" }
      reply(socket, peer: nil, reply: Protocol::Reply.new(ok: false, error: @refusal))
      nil
    end

    # Logs the refusal of *peer* with the failed *check* and replies it.
    private def refuse(socket : UNIXSocket, *, peer : Peer, check : String) : Nil
      @log.warn { "#{describe_peer(peer)} refused check=#{check}" }
      reply(socket, peer: peer, reply: Protocol::Reply.new(ok: false, error: @refusal))
    end

    # The failed check of a refused *admission* for the log: `group` for a
    # peer outside the main group, else `config` and one `name=reason` pair
    # per client configuration, so the operator sees why each one did not
    # apply. A reason of several words is quoted, so each pair reads as one.
    private def refused_check(admission : Authorizer::Admission) : String
      if admission.group_refused?
        GROUP_REFUSED.to_s
      else
        String.build do |io|
          io << CONFIG_REFUSED
          admission.refusals.each do |refusal|
            reason = refusal.refusal.to_s
            io << ' ' << refusal.name << '='
            if reason.includes?(' ') || reason.includes?('=')
              reason.inspect(io)
            else
              io << reason
            end
          end
        end
      end
    end

    # Reads and parses the one request line (UP1). Replies an error and
    # returns nil when it is too long, missing or invalid, or does not
    # arrive in full within `request_timeout`.
    private def read_request(socket : UNIXSocket, *, peer : Peer) : Protocol::Request?
      Protocol::Request.parse(read_line(socket))
    rescue IO::TimeoutError
      fail(socket, peer: peer, operation: nil, name: nil, message: "no request within #{@request_timeout.total_seconds} seconds")
    rescue error : Protocol::Error | IO::Error
      fail(socket, peer: peer, operation: nil, name: nil, message: error.message || "invalid request")
    end

    # Reads up to the first newline under one deadline for the whole line:
    # before each read the read timeout is set to the time left, so a client
    # that drips bytes cannot hold the connection open. Reads at most one
    # byte over `MAX_REQUEST`, which tells a line at the limit from a longer
    # one. Bytes after the newline are ignored; end of stream ends the line.
    private def read_line(socket : UNIXSocket) : String
      deadline = Time.instant + @request_timeout
      line = IO::Memory.new
      chunk = Bytes.new(4_096)
      loop do
        remaining = deadline - Time.instant
        raise IO::TimeoutError.new("Read timed out") unless remaining.positive?

        socket.read_timeout = remaining
        room = Protocol::MAX_REQUEST + 1 - line.size
        count = socket.read(chunk[0, Math.min(chunk.size, room)])
        break if count == 0

        piece = chunk[0, count]
        newline = piece.index('\n'.ord.to_u8)
        if newline
          line.write(piece[0, newline])
          break
        end
        line.write(piece)
        raise Protocol::Error.new("request longer than #{Protocol::MAX_REQUEST} bytes") if line.size > Protocol::MAX_REQUEST
      end
      raise Protocol::Error.new("no request") if line.size == 0

      line.to_s
    end

    private def serve(socket : UNIXSocket, *, admitted : Admitted, request : Protocol::Request) : Nil
      case request
      when Protocol::Create
        create(socket, peer: admitted.peer, admission: admitted.admission, request: request)
      when Protocol::DeviceRequest
        change(socket, peer: admitted.peer, admission: admitted.admission, request: request)
      end
    rescue error
      # Protocol::Error without a message keeps its historic text.
      fallback = error.is_a?(Protocol::Error) ? "error" : error.class.name
      fail(socket, peer: admitted.peer, operation: request.operation, name: request.name, message: error.message || fallback)
    end

    # Creates and configures the device of *request* and passes its
    # descriptor to the client (UP2). An address or route *admission* does
    # not allow is denied before the device exists (CA3). The handler's copy
    # of the descriptor is closed on every path.
    private def create(socket : UNIXSocket, *, peer : Peer, admission : Authorizer::Admission,
                       request : Protocol::Create) : Nil
      denial = admission.allow(addresses: request.addresses, routes: request.routes)
      if denial
        fail(socket, peer: peer, operation: request.operation, name: request.name, message: denial.message, configs: admission.names)
        return
      end

      device = @create_device.call(request.name, request.mtu)
      fd = device.fd
      name = device.name
      begin
        key = configure(peer: peer, name: name, request: request)
      rescue error
        LibC.close(fd)
        # Logged here, where the name the kernel chose is known.
        fail(socket, peer: peer, operation: request.operation, name: name, message: error.message || error.class.name)
        return
      end

      begin
        FdPassing.send(socket, data: reply_bytes(Protocol::Reply.new(ok: true, name: name, key: key)), fd: fd)
        @log.info { "#{describe_peer(peer)} op=create name=#{name} ok" }
      rescue error
        # The client never got the descriptor, so nobody can use the key.
        @registry.remove(name)
        @log.warn { "#{describe_peer(peer)} op=create name=#{name} failed: reply not sent: #{error.message}" }
      ensure
        LibC.close(fd)
      end
    end

    # Runs the commands for a new device *name*, drains the departure
    # events and registers it; returns the key. An entry still registered
    # for *name* is stale, since the kernel only hands out a free unit: it
    # replaces it and logs that at warn, with both interface indexes and no
    # key (UA6, UC5).
    private def configure(*, peer : Peer, name : InterfaceName, request : Protocol::Create) : Key
      run!(Commands.up(name))
      request.addresses.each { |address| run!(Commands.add_address(address, name: name)) }
      request.routes.each { |route| run!(Commands.add_route(route, name: name)) }

      index = @interface_index.call(name)
      raise Protocol::Error.new("#{name} has no interface index") if index == 0

      # The kernel gave out the name only after its previous interface was
      # detached, so the events about that one are buffered by now
      # (unverified, see `DepartureWatcher`).
      @drain_departures.call
      @registry.register(name, index: index, addresses: request.addresses, routes: request.routes) do |stale|
        @log.warn { "#{describe_peer(peer)} op=create name=#{name} replaced stale entry: interface index #{stale.index} now #{index}" }
      end
    end

    # Changes an address or route of a registered device (UP3). Under the
    # registry mutex: checks the interface index (UA6), judges the item by
    # *admission* (CA3), validates the change against the entry, runs the
    # command and only then records it. A rejection or denial becomes an
    # error reply and a log line like any failure; a denial's line names the
    # configurations that applied.
    private def change(socket : UNIXSocket, *, peer : Peer, admission : Authorizer::Admission,
                       request : Protocol::DeviceRequest) : Nil
      refused = @registry.with_entry(request.name, key: request.key) do |entry|
        index = @interface_index.call(entry.name)
        if index == 0 || index != entry.index
          @registry.remove(entry.name)
          @log.info { "#{describe_peer(peer)} op=#{request.operation.wire} name=#{entry.name} removed: interface index #{entry.index} now #{index}" }
          Registry::Rejection.unknown_device
        else
          apply(peer: peer, admission: admission, entry: entry, request: request)
        end
      end
      if refused
        configs = refused.is_a?(Authorizer::Denial) ? admission.names : nil
        fail(socket, peer: peer, operation: request.operation, name: request.name, message: refused.message, configs: configs)
        return
      end

      reply(socket, peer: peer, reply: Protocol::Reply.new(ok: true))
      @log.info { "#{describe_peer(peer)} op=#{request.operation.wire} name=#{request.name} ok" }
    end

    # Checks the change of *request* against *admission* and *entry*, runs
    # its command and records it; returns the denial or the rejection
    # instead, before any command runs, when either refuses it.
    private def apply(*, peer : Peer, admission : Authorizer::Admission, entry : Registry::Entry,
                      request : Protocol::DeviceRequest) : (Registry::Rejection | Authorizer::Denial)?
      name = entry.name
      case request
      when Protocol::AddAddress
        denial = admission.allow(addresses: [request.address], routes: [] of Prefix)
        return denial if denial

        rejection = entry.check_add_address(request.address)
        return rejection if rejection

        run!(Commands.add_address(request.address, name: name))
        entry.add_address(request.address)
      when Protocol::RemoveAddress
        rejection = entry.check_remove_address(request.address)
        return rejection if rejection

        run!(Commands.remove_address(request.address, name: name))
        entry.remove_address(request.address)
      when Protocol::AddRoute
        denial = admission.allow(addresses: [] of Address, routes: [request.route])
        return denial if denial

        rejection = entry.check_add_route(request.route)
        return rejection if rejection

        run!(Commands.add_route(request.route, name: name))
        entry.add_route(request.route)
      when Protocol::RemoveRoute
        rejection = entry.check_remove_route(request.route)
        return rejection if rejection

        remove_route(peer: peer, entry: entry, route: request.route)
      end
    end

    # Removes the route *route* the helper added to the device of *entry*.
    # The kernel's delete matches destination and mask only, so if the
    # route was dropped from the device and someone routed the same prefix
    # elsewhere, a blind delete would remove theirs. The handler first runs
    # `route -n get` and deletes only when its output names the device on
    # an `interface:` line. Otherwise the route is already gone from the
    # device, so the request has its effect: the entry forgets the route,
    # the reply is ok and the log says so. A failing `route -n get` counts
    # as gone too, as the kernel then has no route of the prefix at all.
    private def remove_route(*, peer : Peer, entry : Registry::Entry, route : Prefix) : Registry::Rejection?
      result = @run.call(Commands.get_route(route))
      if result.success? && Commands.routes_to?(result.output, name: entry.name)
        run!(Commands.remove_route(route, name: entry.name))
      else
        @log.info { "#{describe_peer(peer)} op=remove_route name=#{entry.name} route #{route} no longer on #{entry.name}, forgotten" }
      end
      entry.remove_route(route)
    end

    # Runs *argv*; raises `Protocol::Error` with the program, its exit status
    # and its standard error when it fails (UP6).
    private def run!(argv : Array(String)) : Nil
      result = @run.call(argv)
      raise Protocol::Error.new("#{argv[0]} exited #{result.exit_status}: #{result.error.strip}") unless result.success?
    end

    # Logs a failed request and replies its error; returns nil. A nil
    # *operation* is a request that did not parse. *configs* names the
    # client configurations that applied, for a denied item (CD6).
    private def fail(socket : UNIXSocket, *, peer : Peer, operation : Protocol::Operation?, name : InterfaceName?, message : String,
                     configs : Array(String)? = nil) : Nil
      @log.warn do
        line = "#{describe_peer(peer)} op=#{operation.try(&.wire) || "request"} name=#{name || "-"} failed: #{message}"
        configs ? "#{line} configs=#{configs.join(',')}" : line
      end
      reply(socket, peer: peer, reply: Protocol::Reply.new(ok: false, error: message))
      nil
    end

    # Sends *reply* as one line; a client that has gone is only logged.
    private def reply(socket : UNIXSocket, *, peer : Peer?, reply : Protocol::Reply) : Nil
      FdPassing.send(socket, data: reply_bytes(reply))
    rescue error
      @log.warn { "#{describe_peer(peer)} reply not sent: #{error.message}" }
    end

    private def reply_bytes(reply : Protocol::Reply) : Bytes
      "#{reply.to_json}\n".to_slice
    end

    private def describe_peer(peer : Peer?) : String
      peer ? "uid=#{peer.uid} pid=#{peer.pid}" : "uid=? pid=?"
    end
  end
end
