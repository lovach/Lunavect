"""The installed widget is reasserted only for a matching Lunavect copy."""
import importlib.util
import plistlib
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('reassert', ROOT / 'scripts/reassert-installed-widget.py')
reassert = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reassert)


class ReassertInstalledWidgetTests(unittest.TestCase):
    def bundle(self, app, host='com.weekleft.app', widget='com.weekleft.app.widget', build='182', widget_build='182'):
        for path, identifier, version in [(app, host, build), (app / 'Contents/PlugIns/LunavectWidget.appex', widget, widget_build)]:
            info = path / 'Contents/Info.plist'
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier, 'CFBundleVersion': version}))

    def run_case(self, **kwargs):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            copies = reassert.installed_copies(home=home, system=home / 'global')
            self.bundle(copies[0], **kwargs)
            calls = []
            restored = reassert.reassert(copies, run=lambda argv, check: calls.append(argv))
            return restored, calls, copies[0]

    def test_matching_installed_copy_is_registered_host_first(self):
        restored, calls, app = self.run_case()
        self.assertEqual(restored, app)
        self.assertEqual(calls, [[reassert.LSREGISTER, '-f', str(app)], ['pluginkit', '-a', str(app / 'Contents/PlugIns/LunavectWidget.appex')]])

    def test_foreign_or_mismatched_copies_are_left_alone(self):
        for kwargs in [dict(host='other.app'), dict(widget_build='181'), dict(widget='other.widget')]:
            restored, calls, _ = self.run_case(**kwargs)
            self.assertIsNone(restored, kwargs)
            self.assertEqual(calls, [], kwargs)


if __name__ == '__main__':
    unittest.main()
