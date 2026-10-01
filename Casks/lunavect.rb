cask "lunavect" do
  version "0.2.8"
  sha256 "5697072eea04d64fc0591b18731d98fb60c8348979758d6f60a6edfe037fee60"

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
