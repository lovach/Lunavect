import hashlib
import importlib.util
import io
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def load_packager():
    spec = importlib.util.spec_from_file_location("packager", ROOT / "scripts/package-ide-connectors.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def plugin_version(xml):
    return re.search(rb"<version>([^<]+)</version>", xml).group(1).decode()


class IDEConnectorPackagingTests(unittest.TestCase):
    def test_bundled_packages_match_current_sources_and_manifest(self):
        module = load_packager()
        manifest = json.loads((module.OUTPUT / "manifest.json").read_text())
        current = module.source_hashes()
        # Only the JetBrains installer may await a rebuild (it needs the IntelliJ SDK);
        # the pending record must name the exact current sources, so any later edit
        # still requires running the packager.
        pending = manifest.get("pendingSources", {})
        self.assertTrue(all(name.startswith("integrations/jetbrains/") for name in pending), "The VS Code installer can always be rebuilt")
        self.assertEqual({name: current[name] for name in pending if name in current}, pending, "Rerun the packager after changing JetBrains sources")
        self.assertEqual({k: v for k, v in manifest["sources"].items() if k not in pending},
                         {k: v for k, v in current.items() if k not in pending}, "Rebuild the IDE installers after changing their sources")
        for name, expected in manifest["artifacts"].items():
            self.assertEqual(hashlib.sha256((module.OUTPUT / name).read_bytes()).hexdigest(), expected)
        vscode_version = json.loads((ROOT / "integrations/vscode/package.json").read_text())["version"]
        self.assertEqual(manifest["companionVersion"]["vscode"], vscode_version)
        with zipfile.ZipFile(module.OUTPUT / "lunavect-vscode.vsix") as package:
            for name in ["extension.js", "routing.js", "package.json", "README.md"]:
                self.assertEqual(package.read("extension/" + name), (ROOT / "integrations/vscode" / name).read_bytes())
            self.assertNotIn("extension/routing.test.js", package.namelist())
            self.assertNotIn("extension/protocol.test.js", package.namelist())
        source_xml = (ROOT / "integrations/jetbrains/resources/META-INF/plugin.xml").read_bytes()
        with zipfile.ZipFile(module.OUTPUT / "lunavect-jetbrains.zip") as package:
            with zipfile.ZipFile(io.BytesIO(package.read("lunavect-sessions/lib/lunavect-sessions.jar"))) as jar:
                self.assertIn("com/lunavect/sessions/BridgeService.class", jar.namelist())
                bundled_xml = jar.read("META-INF/plugin.xml")
                self.assertEqual(manifest["companionVersion"]["jetbrains"], plugin_version(bundled_xml),
                                 "The manifest names the version actually bundled")
                if not pending:
                    self.assertEqual(bundled_xml, source_xml)
        service = (ROOT / "integrations/jetbrains/src/com/lunavect/sessions/BridgeService.java").read_text()
        self.assertIn('static final String VERSION = "%s";' % plugin_version(source_xml), service,
                      "The JetBrains descriptor reports the plugin.xml version")

    def test_installer_hashes_cover_only_packaged_files(self):
        module = load_packager()
        with tempfile.TemporaryDirectory(prefix="lunavect-packager-") as temporary:
            root = Path(temporary)
            packaged = ["integrations/vscode/package.json", "integrations/vscode/extension.js", "integrations/vscode/routing.js",
                        "integrations/vscode/README.md", "integrations/jetbrains/resources/META-INF/plugin.xml",
                        "integrations/jetbrains/src/com/lunavect/sessions/BridgeService.java"]
            ignored = ["integrations/vscode/routing.test.js", "integrations/vscode/protocol.test.js", "integrations/vscode/extension 2.js",
                       "integrations/vscode/node_modules/pkg/index.js", "integrations/jetbrains/src/com/lunavect/sessions/BridgeService 2.java",
                       "integrations/jetbrains/NOTES.md"]
            for name in packaged + ignored:
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                (root / name).write_text(name)
            original = module.ROOT
            module.ROOT = root
            try:
                hashes = module.source_hashes()
            finally:
                module.ROOT = original
            self.assertEqual(sorted(hashes), sorted(packaged), "Tests, notes and file-sync copies must not require a rebuild")

    @unittest.skipUnless(os.environ.get("LUNAVECT_JETBRAINS_SDK"), "Opt-in JetBrains SDK lifecycle fixture")
    def test_jetbrains_shutdown_cannot_republish_a_heartbeat(self):
        sdk = Path(os.environ["LUNAVECT_JETBRAINS_SDK"]) / "Contents"
        classpath = [str(p) for p in sorted((sdk / "lib").rglob("*.jar")) + sorted((sdk / "plugins/terminal").rglob("*.jar"))]
        with tempfile.TemporaryDirectory(prefix="lunavect-heartbeat-") as temporary:
            root = Path(temporary)
            # Compile the actual current bridge alongside the fixture.
            source = ROOT / "integrations/jetbrains/src/com/lunavect/sessions/BridgeService.java"
            subprocess.run([str(sdk / "jbr/Contents/Home/bin/javac"), "--release", "21", "-cp", ":".join(classpath),
                            "-d", str(root), str(source), str(ROOT / "Tests/Scripts/ide_heartbeat_race.java")], check=True, capture_output=True, timeout=60)
            run = subprocess.run([str(sdk / "jbr/Contents/Home/bin/java"), "-cp", ":".join([str(root), *classpath]),
                                  "IDEHeartbeatRace", str(root)], capture_output=True, text=True, timeout=15)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("PASS:", run.stdout)
