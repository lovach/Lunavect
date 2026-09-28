"""App Info.plist choices from the 28.09 audit (owner decision 20, finding H-09)."""
import plistlib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class AppInfoPlistTests(unittest.TestCase):
    def setUp(self):
        with (ROOT / 'Config/App-Info.plist').open('rb') as file:
            self.info = plistlib.load(file)

    def test_updates_are_checked_daily(self):
        # Sparkle's own default; "Check for updates" stays available at any time.
        self.assertEqual(self.info['SUScheduledCheckInterval'], 86400)

    def test_both_declared_url_schemes_are_routed_by_the_app(self):
        schemes = [scheme for entry in self.info['CFBundleURLTypes'] for scheme in entry['CFBundleURLSchemes']]
        self.assertEqual(sorted(schemes), ['lunavect', 'weekleft'])
        main = (ROOT / 'Sources/Weekleft/Main.swift').read_text()
        for scheme in schemes:
            self.assertTrue(f'"{scheme}"' in main, f'{scheme}:// is declared but never accepted')


if __name__ == '__main__':
    unittest.main()
