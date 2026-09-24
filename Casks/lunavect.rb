cask "lunavect" do
  version "0.2.1"
  sha256 "7313133bce9f21b811c841f09b664b6535582bd4eb4ce4e864bd3c28be2aaadd"

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
