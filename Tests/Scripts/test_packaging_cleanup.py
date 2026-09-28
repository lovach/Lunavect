"""Packaging always retires its exported source, and a failing retirement never
hides why packaging itself failed. The registration cleanup is a subprocess
boundary replaced here; no case reaches Launch Services."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


TOOLS = {
    'package-dmg': ['--app', '/fixture/Lunavect.app', '--output', '/fixture/Lunavect.dmg'],
    'package-update': ['--app', '/fixture/Lunavect.app', '--output', '/fixture/update', '--key-file', '/fixture/key',
                       '--previous-appcast', '/fixture/appcast.xml'],
}
OVERRIDES = ('LUNAVECT_LSREGISTER', 'LUNAVECT_PLUGINKIT', 'LUNAVECT_INSTALLED_APPS')


def clean_environment(**values):
    """The developer's shell must not decide these cases: drop inherited overrides."""
    environment = {key: value for key, value in os.environ.items() if key not in OVERRIDES}
    return mock.patch.dict(os.environ, {**environment, **values}, clear=True)


class PackagingCleanupTests(unittest.TestCase):
    def exercise(self, name, prepare_error=None, cleanup_fails=False, arguments=(), environment=None):
        module, calls = load(name), []
        prepared = []

        def run(argv, **kwargs):
            calls.append([str(item) for item in argv])
            if cleanup_fails and '--retire-app' in argv:
                raise subprocess.CalledProcessError(3, argv)
            return subprocess.CompletedProcess(argv, 0)

        def prepare(args):
            prepared.append(args)
            if prepare_error is not None:
                raise prepare_error

        self.prepared = prepared
        with mock.patch.object(module, 'prepare', side_effect=prepare), \
                mock.patch.object(subprocess, 'run', side_effect=run), \
                mock.patch.object(sys, 'argv', [name] + TOOLS[name] + list(arguments)), \
                clean_environment(**(environment or {})):
            try:
                module.main()
            except BaseException as error:  # the scripts' own exit conversion is tested below
                return error, calls
        return None, calls

    def assert_cleanup_attempted(self, calls):
        self.assertEqual([call[-2:] for call in calls], [['--retire-app', '/fixture/Lunavect.app']])
        self.assertTrue(calls[0][1].endswith('scripts/reassert-installed-widget.py'), calls)

    def test_failed_cleanup_after_failed_packaging_reports_both(self):
        for name in TOOLS:
            with self.subTest(tool=name):
                error, calls = self.exercise(name, ValueError('Synthetic packaging failure'), cleanup_fails=True)
                self.assert_cleanup_attempted(calls)
                self.assertIsNotNone(error)
                message = str(error)
                self.assertIn('Synthetic packaging failure', message)
                self.assertIn('cleanup also failed', message)
                self.assertIn('non-zero exit status 3', message)

    def test_successful_cleanup_preserves_the_original_error(self):
        for name in TOOLS:
            with self.subTest(tool=name):
                original = ValueError('Synthetic packaging failure')
                error, calls = self.exercise(name, original)
                self.assert_cleanup_attempted(calls)
                self.assertIs(error, original)

    def test_failed_cleanup_after_successful_packaging_still_fails(self):
        for name in TOOLS:
            with self.subTest(tool=name):
                error, calls = self.exercise(name, cleanup_fails=True)
                self.assert_cleanup_attempted(calls)
                self.assertIsInstance(error, subprocess.CalledProcessError)

    def test_successful_packaging_retires_the_export_once(self):
        for name in TOOLS:
            with self.subTest(tool=name):
                error, calls = self.exercise(name)
                self.assertIsNone(error)
                self.assert_cleanup_attempted(calls)

    def test_registration_overrides_are_refused_without_the_fixture_flag(self):
        """R3-08 covered distribute.sh and release-preflight.py only. Packaging is a
        release step too: a shim or an empty LUNAVECT_INSTALLED_APPS left in the
        shell would silently replace the cleanup of the notarized export and the
        installed widget's reassertion."""
        for name in TOOLS:
            for override, value in (('LUNAVECT_LSREGISTER', '/tmp/lv-shim/lsregister'),
                                    ('LUNAVECT_PLUGINKIT', '/tmp/lv-shim/pluginkit'), ('LUNAVECT_INSTALLED_APPS', '')):
                with self.subTest(tool=name, override=override):
                    error, calls = self.exercise(name, environment={override: value})
                    self.assertIsInstance(error, SystemExit)
                    self.assertNotEqual(error.code, 0)
                    self.assertEqual(calls, [], 'Refusal must come before any registration cleanup')
                    self.assertEqual(self.prepared, [], 'Refusal must come before packaging')
                with self.subTest(tool=name, override=override, fixture=True):
                    error, calls = self.exercise(name, environment={override: value}, arguments=['--test-fixture'])
                    self.assertIsNone(error)
                    self.assert_cleanup_attempted(calls)

    def test_command_line_exit_reports_both_errors_and_is_nonzero(self):
        for name in TOOLS:
            with self.subTest(tool=name):
                module = load(name)
                both = module.CleanupFailed(ValueError('Synthetic packaging failure'),
                                            subprocess.CalledProcessError(3, ['reassert']))
                with mock.patch.object(module, 'main', side_effect=both):
                    with self.assertRaises(SystemExit) as caught:
                        module.entry()
                self.assertIsInstance(caught.exception.code, str)  # a message exits with status 1
                self.assertIn('Synthetic packaging failure', caught.exception.code)
                self.assertIn('cleanup also failed', caught.exception.code)


class PackageUpdateGateTests(unittest.TestCase):
    """package-update.py refuses unsafe inputs before it runs codesign, Sparkle's
    tools or ditto. subprocess.run is replaced by a guard that fails the test."""

    def setUp(self):
        import plistlib
        import tempfile
        temporary = tempfile.TemporaryDirectory(prefix="lunavect update gate 'q' ")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.app = self.base / 'Lunavect.app'
        (self.app / 'Contents').mkdir(parents=True)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.weekleft.app', 'CFBundleShortVersionString': '0.2.5', 'CFBundleVersion': '192',
            'SUFeedURL': 'https://github.com/lovach/Lunavect/releases/latest/download/appcast.xml',
            'SUPublicEDKey': 'jytrM6mKxv4rA4YmTFMeuftsQ1x7P3O01pbUIO07xVY=',
            'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True}))
        self.feed = self.base / 'appcast.xml'
        self.feed.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
                             '<enclosure sparkle:version="191" sparkle:shortVersionString="0.2.4"/></item></channel></rss>')
        self.key = self.base / 'private-key'
        self.key.write_text('fixture key, never used\n')
        self.key.chmod(0o600)
        self.module = load('package-update')

    def prepare(self, **changes):
        import argparse
        values = dict(app=self.app, output=self.base / 'release-assets', key_file=self.key,
                      tools=self.base / 'sparkle-bin', previous_appcast=self.feed, test_fixture=False)
        values.update(changes)
        forbidden = mock.Mock(side_effect=AssertionError('A tool ran before the input gate'))
        with mock.patch.object(subprocess, 'run', forbidden):
            with self.assertRaises(ValueError) as caught:
                self.module.prepare(argparse.Namespace(**values))
        forbidden.assert_not_called()
        return str(caught.exception)

    def test_key_readable_by_others_is_refused(self):
        for mode in (0o644, 0o640, 0o604):
            with self.subTest(mode=oct(mode)):
                self.key.chmod(mode)
                self.assertIn('owner-only permissions', self.prepare())

    def test_missing_key_is_refused(self):
        self.assertIn('owner-only permissions', self.prepare(key_file=self.base / 'missing-key'))

    def test_key_inside_the_project_is_refused(self):
        inside = ROOT / 'build' / ('update-gate-key-' + os.urandom(4).hex())
        if not inside.parent.exists():
            inside.parent.mkdir()
            self.addCleanup(inside.parent.rmdir)
        inside.write_text('fixture key, never used\n')
        inside.chmod(0o600)
        self.addCleanup(inside.unlink)
        self.assertIn('outside the project', self.prepare(key_file=inside))

    def test_existing_output_is_never_reused(self):
        (self.base / 'release-assets').mkdir()
        self.assertIn('Output directory already exists', self.prepare())

    def test_same_or_older_release_is_refused_before_packaging(self):
        self.feed.write_text(self.feed.read_text().replace('191', '192'))
        self.assertIn('exceed every build', self.prepare())


if __name__ == '__main__':
    unittest.main()
