cask "lunavect" do
  version "0.1.9"
  sha256 "b7082dc27c507f17422489c961c63aae18df945cb13c7eac15eac481a69244fc"

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
