# The `tunnelgeist` program: the macOS daemon, or a stub elsewhere. Each is a
# whole unit of its own; this file only picks one.
{% if flag?(:darwin) %}
  require "./tunnelgeist_macos"
{% else %}
  require "./tunnelgeist_other"
{% end %}
