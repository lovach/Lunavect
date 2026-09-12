cask "lunavect" do
  version "0.1.0"
  sha256 "e23e4eb272b6aadbefdbc9cdcced23720d9cd82c421bd06871497d3a8df1baf2"

  url "https://github.com/lovach/Lunavect/releases/download/v#{version}/Lunavect-#{version}-installer-2.dmg"
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
