"""The installed widget is reasserted only for a matching Lunavect copy."""
import importlib.util
import plistlib
import subprocess
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('reassert', ROOT / 'scripts/reassert-installed-widget.py')
reassert = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reassert)


class ReassertInstalledWidgetTests(unittest.TestCase):
    def test_failed_unregister_accepts_only_confirmed_absence(self):
        app = Path('/tmp/owned-fixture.app')
        for present in [False, True]:
            def run(argv, **kwargs):
                if argv[1] == '-u':
                    raise subprocess.CalledProcessError(1, argv, stderr='failed to scan: -10814')
                self.assertEqual(argv[1], '-dump')
                return subprocess.CompletedProcess(argv, 0, stdout=f'path: {app} (0x1)\n' if present else '')
            if present:
                with self.assertRaises(subprocess.CalledProcessError):
                    reassert.unregister(app, run=run)
            else:
                reassert.unregister(app, run=run)

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

    def test_two_installed_copies_register_only_the_canonical_one(self):
        """Matrix W8: with ~/Applications and /Applications both valid, only the
        canonical user copy is registered; the other copy is never switched in."""
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            copies = reassert.installed_copies(home=home, system=home / 'global')
            for app in copies:
                self.bundle(app)
            calls = []
            restored = reassert.reassert(copies, run=lambda argv, check: calls.append(argv))
            self.assertEqual(restored, home / 'Applications/Lunavect.app')
            registered = [argv[-1] for argv in calls]
            self.assertEqual(registered, [str(copies[0]), str(copies[0] / 'Contents/PlugIns/LunavectWidget.appex')])
            self.assertFalse(any(str(copies[1]) in argument for argv in calls for argument in argv))

    def test_foreign_or_mismatched_copies_are_left_alone(self):
        for kwargs in [dict(host='other.app'), dict(widget_build='181'), dict(widget='other.widget')]:
            restored, calls, _ = self.run_case(**kwargs)
            self.assertIsNone(restored, kwargs)
            self.assertEqual(calls, [], kwargs)

    def test_temporary_copy_is_retired_before_installed_host_is_reasserted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            installed, exported = root / 'Applications/Lunavect.app', root / 'export/Lunavect.app'
            self.bundle(installed); self.bundle(exported)
            calls = []
            def run(argv, check):
                self.assertTrue((exported / 'Contents/Info.plist').exists())
                calls.append(argv)
            self.assertEqual(reassert.retire_temporary([exported], [installed], run=run), [exported])
            self.assertEqual(calls, [
                ['pluginkit', '-r', str(exported / 'Contents/PlugIns/LunavectWidget.appex')],
                [reassert.LSREGISTER, '-u', str(exported)],
                [reassert.LSREGISTER, '-f', str(installed)],
                ['pluginkit', '-a', str(installed / 'Contents/PlugIns/LunavectWidget.appex')]])
            self.assertTrue((exported / 'Contents/Info.plist').exists(), 'Cleanup never deletes the packaged source')

    def test_retirement_preserves_installed_aliases_foreign_and_missing_apps(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); installed = root / 'Applications/Lunavect.app'
            alias, foreign, missing = root / 'alias.app', root / 'foreign.app', root / 'missing.app'
            self.bundle(installed); self.bundle(foreign, host='other.app'); alias.symlink_to(installed)
            calls = []
            retired = reassert.retire_temporary([installed, alias, foreign, missing], [installed],
                                                run=lambda argv, check: calls.append(argv))
            self.assertEqual(retired, []); self.assertEqual(calls, [])

    def test_failed_retirement_still_reasserts_installed_host(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); installed, exported = root / 'installed.app', root / 'exported.app'
            self.bundle(installed); self.bundle(exported); calls = []
            def run(argv, check):
                calls.append(argv)
                if argv[:2] == [reassert.LSREGISTER, '-u']:
                    raise RuntimeError('Synthetic unregister failure')
            with self.assertRaisesRegex(RuntimeError, 'Synthetic'):
                reassert.retire_temporary([exported], [installed], run=run)
            self.assertEqual(calls[-2:], [[reassert.LSREGISTER, '-f', str(installed)],
                              ['pluginkit', '-a', str(installed / 'Contents/PlugIns/LunavectWidget.appex')]])


if __name__ == '__main__':
    unittest.main()
