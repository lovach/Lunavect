cask "lunavect" do
  version "0.1.3"
  sha256 "269b42b0e1840789417f61a97100fe4c29193c70a8b20cb2ba46236c2f855575"

  url "https://github.com/lovach/Lunavect/releases/download/v#{version}/Lunavect-#{version}.dmg"
  name "Lunavect"
  desc "Claude Code and Codex session status, usage limits, and desktop widgets"
  homepage "https://github.com/lovach/Lunavect"

  auto_updates true
  depends_on macos: :sonoma

  app "Lunavect.app"

  caveats <<~EOS
    Before uninstalling, disconnect Claude and Codex in Settings > Connections
    so their previous event handlers and status line can be restored.
  EOS
end
