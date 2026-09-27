import hashlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
from pathlib import Path
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]


class IDEConnectorPackagingTests(unittest.TestCase):
    def test_bundled_packages_match_current_sources_and_manifest(self):
        spec = importlib.util.spec_from_file_location("packager", ROOT / "scripts/package-ide-connectors.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        manifest = json.loads((module.OUTPUT / "manifest.json").read_text())
        self.assertEqual(manifest["sources"], module.source_hashes(), "Rebuild the IDE installers after changing their sources")
        for name, expected in manifest["artifacts"].items():
            self.assertEqual(hashlib.sha256((module.OUTPUT / name).read_bytes()).hexdigest(), expected)
        with zipfile.ZipFile(module.OUTPUT / "lunavect-vscode.vsix") as package:
            for name in ["extension.js", "routing.js", "package.json"]:
                self.assertEqual(package.read("extension/" + name), (ROOT / "integrations/vscode" / name).read_bytes())
            self.assertNotIn("extension/routing.test.js", package.namelist())
        with zipfile.ZipFile(module.OUTPUT / "lunavect-jetbrains.zip") as package:
            with zipfile.ZipFile(io.BytesIO(package.read("lunavect-sessions/lib/lunavect-sessions.jar"))) as jar:
                self.assertIn("com/lunavect/sessions/BridgeService.class", jar.namelist())
                self.assertEqual(jar.read("META-INF/plugin.xml"), (ROOT / "integrations/jetbrains/resources/META-INF/plugin.xml").read_bytes())

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
