"""Exercise distribution cleanup with an invalidating registration service fixture."""
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


class DistributionRegistrationTests(unittest.TestCase):
    def test_cleanup_restores_installed_host_after_every_temporary_removal(self):
        self.exercise()

    def test_foreign_installed_bundle_is_not_registered(self):
        self.exercise(identifier='other.app')

    def test_mismatched_widget_build_is_not_registered(self):
        self.exercise(widget_version='162')

    def test_failed_host_registration_is_reported(self):
        self.exercise(fail=True)

    def exercise(self, identifier='com.weekleft.app', widget_version='163', fail=False):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            archive, output = home / 'Archive.xcarchive', home / 'output'
            installed = home / 'Applications/Lunavect.app'
            exported = archive / 'Products/Applications/Lunavect.app'
            for app, host_id, version in [(installed, identifier, widget_version), (exported, 'com.weekleft.app', '163')]:
                for bundle, bundle_id, build in [(app, host_id, '163'), (app / 'Contents/PlugIns/LunavectWidget.appex', 'com.weekleft.app.widget', version)]:
                    info = bundle / 'Contents/Info.plist'
                    info.parent.mkdir(parents=True)
                    info.write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle_id, 'CFBundleVersion': build}))
            source = (ROOT / 'scripts/distribute.sh').read_text().split('python3 - "$ARCHIVE" "$OUTPUT" "$BUILD" <<\'PY\'\n', 1)[1].split('\nPY\n', 1)[0]
            # Isolate the fallback install root as well as the home directory.
            source = source.replace("Path('/Applications/Lunavect.app')", "Path(" + repr(str(home / 'global/Lunavect.app')) + ")")
            trace, lookup = [], {'valid': True}
            def run(argv, **kwargs):
                trace.append(argv)
                if argv[1] in ('-u', '-r'):
                    lookup['valid'] = False
                elif argv[1] == '-f':
                    if fail:
                        raise subprocess.CalledProcessError(42, argv)
                    self.assertEqual(argv[2], str(installed))
                    lookup['valid'] = True
                elif argv[1] == '-a':
                    self.assertTrue(lookup['valid'], 'Extension registered without its host')
                return subprocess.CompletedProcess(argv, 0)
            with patch('pathlib.Path.home', return_value=home), patch('sys.argv', ['cleanup', str(archive), str(output), '163']), patch('subprocess.check_output', return_value=f'path: {exported} (0x1)\n'), patch('subprocess.run', side_effect=run), patch('builtins.print'):
                if fail:
                    with self.assertRaises(subprocess.CalledProcessError):
                        exec(compile(source, 'distribution-cleanup', 'exec'), {})
                else:
                    exec(compile(source, 'distribution-cleanup', 'exec'), {})
            self.assertTrue(any(argv[1] == '-r' for argv in trace))
            valid = identifier == 'com.weekleft.app' and widget_version == '163'
            if valid and not fail:
                self.assertTrue(lookup['valid'])
                self.assertEqual([argv[1] for argv in trace[-2:]], ['-f', '-a'])
            elif not valid:
                self.assertFalse(any(argv[1] in ('-f', '-a') for argv in trace))
