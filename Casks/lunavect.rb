cask "lunavect" do
  version "0.2.0"
  sha256 "3748dc7d0099aba234e273beb5ed2a02154f2a49283cd7da6467eb3b0ac4ff73"

  url "https://github.com/lovach/Lunavect/releases/download/v#{version}/Lunavect-#{version}.dmg"
  name "Lunavect"
  desc "Claude Code and Codex session status, usage limits, and desktop widgets"
  homepage "https://github.com/lovach/Lunavect"

  auto_updates true
  depends_on macos: :sonoma

  app "Lunavect.app"

  uninstall quit: "com.weekleft.app"

  caveats <<~EOS
    Before uninstalling, disconnect Claude and Codex in Settings > Connections
    so their previous event handlers and status line can be restored.

    If you used Keep Awake, stop it and quit Lunavect, then remove its
    system helper before uninstalling:
      "#{appdir}/Lunavect.app/Contents/MacOS/Lunavect" --unregister-awake-helper
    Complete removal steps:
      https://github.com/lovach/Lunavect/blob/main/docs/updates.md#complete-removal
  EOS
end
