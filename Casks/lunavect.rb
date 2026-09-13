cask "lunavect" do
  version "0.1.1"
  sha256 "5fe1908dbe9455bb96692762d605432a6c255f7c1245d6a37adbf01a6df44d1f"

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
