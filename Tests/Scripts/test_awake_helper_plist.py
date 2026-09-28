"""Lint the Keep Awake launch daemon definition (audit H-02, owner decision 16).

launchd must start the helper only at boot (recovery) and on demand through its
Mach service. A KeepAlive rule turns any permanent failure, such as a program
that no longer exists at the registered path, into a respawn every 30 seconds.
"""
import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLIST = ROOT / 'Config/com.weekleft.awake-helper.plist'
PROTOCOL = ROOT / 'Sources/AwakeService/AwakeProtocol.swift'
PROJECT = ROOT / 'project.yml'
HELPER_PATH = 'Contents/Library/LaunchServices/LunavectAwakeHelper'


def service_label():
    match = re.search(r'public static let label = "([^"]+)"', PROTOCOL.read_text())
    if not match:
        raise AssertionError('AwakeServiceID.label not found')
    return match.group(1)


class AwakeHelperPlistTests(unittest.TestCase):
    def setUp(self):
        with PLIST.open('rb') as file:
            self.plist = plistlib.load(file)
        self.label = service_label()

    def test_identity_matches_the_service_the_app_connects_to(self):
        self.assertEqual(self.plist['Label'], self.label)
        self.assertEqual(self.plist['MachServices'], {self.label: True})
        self.assertEqual(self.plist['BundleProgram'], HELPER_PATH)

    def test_no_rule_respawns_a_helper_that_exited_or_could_not_start(self):
        self.assertNotIn('KeepAlive', self.plist, 'decision 16: MachServices and RunAtLoad start the helper')
        self.assertIs(self.plist.get('RunAtLoad'), True, 'boot-time recovery of an interrupted lease')

    def test_bundle_places_program_and_definition_where_the_plist_says(self):
        project = PROJECT.read_text()
        self.assertIn('/' + HELPER_PATH + '"', project)
        self.assertIn(f'Contents/Library/LaunchDaemons/{self.label}.plist"', project)
        self.assertIn(f'Config/{self.label}.plist"', project)


if __name__ == '__main__':
    unittest.main()
