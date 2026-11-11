require "../test_helper"
require "../../src/tunnelgeist/client"
require "../../src/tunnelgeist/lib_system"
require "./support/temporary_directory"

# The client library `Tunnelgeist::Client` (TA2) where the outcome depends on
# whether the process runs as root.
describe TunnelgeistClient do
  {% if flag?(:darwin) %}
    include TunnelgeistTemporaryDirectory

    alias Client = Tunnelgeist::Client

    test "device refuses a descriptor that is no utun with the lookup's own error and connects nowhere" do
      reader, writer = IO.pipe
      begin
        error = raised(IO::Error) { Client.new("/nonexistent/tunnelgeist.sock").device(reader.fd) }

        assert(!error.is_a?(Client::Error))
        assert(error.os_error == Errno::ENOTSOCK)
        assert(!reader.closed?)
      ensure
        reader.close
        writer.close
      end
    end

    test "a socket the caller may not connect to raises Client::Error with the connection refused" do
      # Root may connect regardless of the mode, so the refusal needs an
      # unprivileged process.
      skip("root may connect to any socket") if Tunnelgeist::LibSystem.geteuid == 0

      with_temporary_directory do |directory|
        path = socket_path(directory, name: "denied")
        server = UNIXServer.new(path)
        begin
          File.chmod(path, 0o000)
          error = raised(Client::Error) { Client.new(path).create }
          assert(error.message == "tunnelgeist refused the connection (#{path}): not permitted")
          assert(error.reason.connection_refused?)
        ensure
          server.close
        end
      end
    end
  {% end %}
end
