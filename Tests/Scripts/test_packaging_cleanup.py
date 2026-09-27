"""Packaging always retires its exported source, and a failing retirement never
hides why packaging itself failed. The registration cleanup is a subprocess
boundary replaced here; no case reaches Launch Services."""
import importlib.util
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


class PackagingCleanupTests(unittest.TestCase):
    def exercise(self, name, prepare_error=None, cleanup_fails=False):
        module, calls = load(name), []

        def run(argv, **kwargs):
            calls.append([str(item) for item in argv])
            if cleanup_fails and '--retire-app' in argv:
                raise subprocess.CalledProcessError(3, argv)
            return subprocess.CompletedProcess(argv, 0)

        with mock.patch.object(module, 'prepare', side_effect=prepare_error), \
                mock.patch.object(subprocess, 'run', side_effect=run), \
                mock.patch.object(sys, 'argv', [name] + TOOLS[name]):
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


if __name__ == '__main__':
    unittest.main()
