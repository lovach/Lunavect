#!/usr/bin/env python3
"""Build the bundled, offline IDE installers from this checkout.

Requires an IntelliJ IDEA 2026.2 SDK app with its bundled javac. No credentials,
Marketplace uploads, package downloads or changes to installed editors occur.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Sources/Weekleft/Resources/IDEConnectors"


def archive(entries):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as result:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            result.writestr(info, data)
    return output.getvalue()


def source_hashes():
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted((ROOT / "integrations").rglob("*")) if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jetbrains-sdk", required=True, type=Path)
    args = parser.parse_args()
    sdk = args.jetbrains_sdk / "Contents"
    info = plistlib.loads((sdk / "Info.plist").read_bytes())
    build = (sdk / "Resources/build.txt").read_text().strip()
    if not build.startswith("IU-262."):
        parser.error("Use the verified IntelliJ IDEA 2026.2 SDK (build IU-262.*)")
    vscode = ROOT / "integrations/vscode"
    version = json.loads((vscode / "package.json").read_text())["version"]
    entries = {"extension/" + name: (vscode / name).read_bytes()
               for name in ["package.json", "extension.js", "routing.js", "README.md"]}
    entries["extension/LICENSE.txt"] = (ROOT / "LICENSE").read_bytes()
    entries["[Content_Types].xml"] = b'''<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="json" ContentType="application/json"/><Default Extension="js" ContentType="application/javascript"/><Default Extension="md" ContentType="text/markdown"/><Default Extension="txt" ContentType="text/plain"/><Default Extension="vsixmanifest" ContentType="text/xml"/></Types>'''
    entries["extension.vsixmanifest"] = f'''<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011"><Metadata><Identity Language="en-US" Id="lunavect" Version="{version}" Publisher="lovach"/><DisplayName>Lunavect Sessions</DisplayName><Description xml:space="preserve">Focus existing Claude and Codex sessions from Lunavect.</Description><Tags/><Categories>Other</Categories><GalleryFlags>Public</GalleryFlags><Properties><Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.94.0"/><Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui"/></Properties><License>extension/LICENSE.txt</License></Metadata><Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation><Dependencies/><Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/><Asset Type="Microsoft.VisualStudio.Services.Content.Details" Path="extension/README.md" Addressable="true"/><Asset Type="Microsoft.VisualStudio.Services.Content.License" Path="extension/LICENSE.txt" Addressable="true"/></Assets></PackageManifest>'''.encode()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / "lunavect-vscode.vsix").write_bytes(archive(entries))
    with tempfile.TemporaryDirectory(prefix="lunavect-ide-compile-") as temporary:
        classes = Path(temporary)
        classpath = ":".join(str(p) for p in sorted((sdk / "lib").rglob("*.jar")) + sorted((sdk / "plugins/terminal").rglob("*.jar")))
        sources = sorted((ROOT / "integrations/jetbrains/src").rglob("*.java"))
        subprocess.run([str(sdk / "jbr/Contents/Home/bin/javac"), "--release", "21", "-cp", classpath,
                        "-d", str(classes), *map(str, sources)], check=True)
        jar = {str(p.relative_to(classes)): p.read_bytes() for p in classes.rglob("*.class")}
        jar["META-INF/plugin.xml"] = (ROOT / "integrations/jetbrains/resources/META-INF/plugin.xml").read_bytes()
        jar["META-INF/LICENSE.txt"] = (ROOT / "LICENSE").read_bytes()
        (OUTPUT / "lunavect-jetbrains.zip").write_bytes(archive({"lunavect-sessions/lib/lunavect-sessions.jar": archive(jar)}))
    manifest = {"version": 1, "jetbrainsSDK": build, "jetbrainsVersion": info["CFBundleShortVersionString"],
                "sources": source_hashes(), "artifacts": {name: hashlib.sha256((OUTPUT / name).read_bytes()).hexdigest()
                for name in ["lunavect-vscode.vsix", "lunavect-jetbrains.zip"]}}
    (OUTPUT / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print("Built VS Code and JetBrains installers in", OUTPUT)


if __name__ == "__main__":
    main()
