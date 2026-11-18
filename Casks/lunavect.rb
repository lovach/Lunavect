cask "lunavect" do
  version "0.3.0"
  sha256 "1320621c44bd711b1ea133027e0dbe9d5cdd50d81d7b0531ed1bea9e7c09242f"

  url "https://github.com/lovach/Lunavect/releases/download/v#{version}/Lunavect-#{version}.dmg"
  name "Lunavect"
  desc "Claude Code and Codex session status, usage limits, and desktop widgets"
  homepage "https://github.com/lovach/Lunavect"

  livecheck do
    url :url
    strategy :github_latest
  end

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
