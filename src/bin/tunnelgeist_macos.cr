{% skip_file unless flag?(:darwin) %}

require "../tunnelgeist/cli"

# The composition root of the daemon: the only place that hands the real
# streams and environment to `Tunnelgeist::CLI`.
exit Tunnelgeist::CLI.run(ARGV, output: STDOUT, error: STDERR, sudo_user: ENV["SUDO_USER"]?)
