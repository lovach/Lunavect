#!/usr/bin/env python3
"""Build the bundled, offline IDE installers from this checkout.

A full build requires an IntelliJ IDEA 2026.2 SDK app with its bundled javac.
Without it, --vscode-only rebuilds the VS Code installer, keeps the bundled
JetBrains installer and records JetBrains sources changed since its build as
pending. No credentials, Marketplace uploads, package downloads or changes to
installed editors occur.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Sources/Weekleft/Resources/IDEConnectors"
VSCODE_FILES = ["package.json", "extension.js", "routing.js", "README.md"]
JETBRAINS_JAR = "lunavect-sessions/lib/lunavect-sessions.jar"
# File-sync conflict copies such as "BridgeService 2.java" are never packaged.
CONFLICT = re.compile(r"^.+ [0-9]+(?:\.[^./ ]+)*$")


def archive(entries):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as result:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            result.writestr(info, data)
    return output.getvalue()


def jetbrains_sources():
    return sorted(p for p in (ROOT / "integrations/jetbrains/src").rglob("*.java") if not CONFLICT.match(p.name))


def artifact_sources():
    """Exactly the files that go into the installers; tests and notes need no rebuild."""
    vscode = [ROOT / "integrations/vscode" / name for name in VSCODE_FILES]
    return vscode + [ROOT / "integrations/jetbrains/resources/META-INF/plugin.xml"] + jetbrains_sources()


def source_hashes():
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in artifact_sources() if p.is_file()}


def is_jetbrains(name):
    return name.startswith("integrations/jetbrains/")


def plugin_version(xml):
    return re.search(rb"<version>([^<]+)</version>", xml).group(1).decode()


def bundled_jetbrains_version():
    with zipfile.ZipFile(OUTPUT / "lunavect-jetbrains.zip") as package:
        with zipfile.ZipFile(io.BytesIO(package.read(JETBRAINS_JAR))) as jar:
            return plugin_version(jar.read("META-INF/plugin.xml"))


def build_vscode():
    vscode = ROOT / "integrations/vscode"
    version = json.loads((vscode / "package.json").read_text())["version"]
    entries = {"extension/" + name: (vscode / name).read_bytes() for name in VSCODE_FILES}
    entries["extension/LICENSE.txt"] = (ROOT / "LICENSE").read_bytes()
    entries["[Content_Types].xml"] = b'''<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="json" ContentType="application/json"/><Default Extension="js" ContentType="application/javascript"/><Default Extension="md" ContentType="text/markdown"/><Default Extension="txt" ContentType="text/plain"/><Default Extension="vsixmanifest" ContentType="text/xml"/></Types>'''
    entries["extension.vsixmanifest"] = f'''<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011"><Metadata><Identity Language="en-US" Id="lunavect" Version="{version}" Publisher="lovach"/><DisplayName>Lunavect Sessions</DisplayName><Description xml:space="preserve">Focus existing Claude and Codex sessions from Lunavect.</Description><Tags/><Categories>Other</Categories><GalleryFlags>Public</GalleryFlags><Properties><Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.94.0"/><Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui"/></Properties><License>extension/LICENSE.txt</License></Metadata><Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation><Dependencies/><Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/><Asset Type="Microsoft.VisualStudio.Services.Content.Details" Path="extension/README.md" Addressable="true"/><Asset Type="Microsoft.VisualStudio.Services.Content.License" Path="extension/LICENSE.txt" Addressable="true"/></Assets></PackageManifest>'''.encode()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / "lunavect-vscode.vsix").write_bytes(archive(entries))
    return version


def build_jetbrains(sdk):
    with tempfile.TemporaryDirectory(prefix="lunavect-ide-compile-") as temporary:
        classes = Path(temporary)
        classpath = ":".join(str(p) for p in sorted((sdk / "lib").rglob("*.jar")) + sorted((sdk / "plugins/terminal").rglob("*.jar")))
        subprocess.run([str(sdk / "jbr/Contents/Home/bin/javac"), "--release", "21", "-cp", classpath,
                        "-d", str(classes), *map(str, jetbrains_sources())], check=True)
        jar = {str(p.relative_to(classes)): p.read_bytes() for p in classes.rglob("*.class")}
        jar["META-INF/plugin.xml"] = (ROOT / "integrations/jetbrains/resources/META-INF/plugin.xml").read_bytes()
        jar["META-INF/LICENSE.txt"] = (ROOT / "LICENSE").read_bytes()
        (OUTPUT / "lunavect-jetbrains.zip").write_bytes(archive({JETBRAINS_JAR: archive(jar)}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jetbrains-sdk", type=Path)
    parser.add_argument("--vscode-only", action="store_true",
                        help="keep the bundled JetBrains installer; its changed sources are recorded as pending")
    args = parser.parse_args()
    if args.vscode_only == (args.jetbrains_sdk is not None):
        parser.error("Pass either --jetbrains-sdk or --vscode-only")
    current = source_hashes()
    previous = json.loads((OUTPUT / "manifest.json").read_text()) if (OUTPUT / "manifest.json").exists() else {}
    if args.vscode_only:
        # The JetBrains installer stays as bundled; keep what it was built from.
        artifact = hashlib.sha256((OUTPUT / "lunavect-jetbrains.zip").read_bytes()).hexdigest()
        if previous.get("artifacts", {}).get("lunavect-jetbrains.zip") != artifact:
            parser.error("The bundled JetBrains installer does not match the previous manifest")
    vscode_version = build_vscode()
    sources = {name: digest for name, digest in current.items() if not is_jetbrains(name)}
    pending = {}
    if args.vscode_only:
        built = {name: digest for name, digest in previous.get("sources", {}).items() if is_jetbrains(name)}
        sources.update(built)
        pending = {name: digest for name, digest in current.items() if is_jetbrains(name) and built.get(name) != digest}
        build, jetbrains_version = previous["jetbrainsSDK"], previous["jetbrainsVersion"]
    else:
        sdk = args.jetbrains_sdk / "Contents"
        info = plistlib.loads((sdk / "Info.plist").read_bytes())
        build = (sdk / "Resources/build.txt").read_text().strip()
        if not build.startswith("IU-262."):
            parser.error("Use the verified IntelliJ IDEA 2026.2 SDK (build IU-262.*)")
        build_jetbrains(sdk)
        jetbrains_version = info["CFBundleShortVersionString"]
        sources.update({name: digest for name, digest in current.items() if is_jetbrains(name)})
    manifest = {"version": 1, "jetbrainsSDK": build, "jetbrainsVersion": jetbrains_version, "sources": sources,
                "companionVersion": {"vscode": vscode_version, "jetbrains": bundled_jetbrains_version()},
                "artifacts": {name: hashlib.sha256((OUTPUT / name).read_bytes()).hexdigest()
                              for name in ["lunavect-vscode.vsix", "lunavect-jetbrains.zip"]}}
    if pending:
        manifest["pendingSources"] = pending
    (OUTPUT / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print("Built the VS Code installer in" if args.vscode_only else "Built VS Code and JetBrains installers in", OUTPUT)
    if pending:
        print("The JetBrains installer awaits a rebuild with --jetbrains-sdk for:", ", ".join(sorted(pending)))


if __name__ == "__main__":
    main()
