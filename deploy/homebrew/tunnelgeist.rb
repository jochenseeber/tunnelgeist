# The Homebrew formula of tunnelgeist, kept here as a template and copied into
# the tap (github.com/jochenseeber/homebrew-tap) for each release. Version
# 0.0.0 and the zero checksums are placeholders, never committed with real
# values: `rake homebrew:formula:update` fills them in from the release
# archives under dist/, and `rake homebrew:tap` publishes the result. The URLs
# follow the version through #{version}.
class Tunnelgeist < Formula
  desc "Root helper that creates and configures utun devices for unprivileged programs"
  homepage "https://github.com/jochenseeber/tunnelgeist"
  version "0.0.0"
  license "MIT"

  depends_on arch: :arm64
  depends_on :macos

  on_macos do
    on_arm do
      url "https://github.com/jochenseeber/tunnelgeist/releases/download/v#{version}/tunnelgeist-darwin-arm64-system-static.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  def install
    bin.install "tunnelgeist"
  end

  def caveats
    <<~EOS
      tunnelgeist runs as root, so it never runs the program Homebrew
      installed, which your user can replace. Install the daemon with:
        sudo tunnelgeist install
      It copies the program into root-owned /usr/local/libexec, writes the
      starter configuration to /usr/local/etc/tunnelgeist/config.json and a
      LaunchDaemon that starts it on demand. Run it again after every upgrade.
      Members of the group tunnelgeist may use the daemon.
    EOS
  end

  test do
    assert_match "Usage: tunnelgeist", shell_output("#{bin}/tunnelgeist help")
  end
end
