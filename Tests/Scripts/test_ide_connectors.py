import hashlib
import importlib.util
import io
import json
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
