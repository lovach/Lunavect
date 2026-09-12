import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('migration', Path(__file__).parents[2] / 'scripts/migrate-app-group.py')
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class GroupMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.old_group, self.new_group = 'group.com.weekleft.shared', 'TESTTEAM01.com.lunavect.shared'
        self.old, self.new = self.app('Old', self.old_group), self.app('New', self.new_group)
        self.source = self.home / 'Library/Group Containers' / self.old_group
        self.destination = self.source.parent / self.new_group
        (self.source / 'Weekleft').mkdir(parents=True)
        self.snapshot = b'{"preferences":{"enabledProviders":["claude"],"transparency":0.7},"snapshots":[]}'
        (self.source / 'Weekleft/snapshot.json').write_bytes(self.snapshot)
        (self.source / 'Weekleft/activity.json').write_bytes(b'{"intervals":[]}')
        prefs = self.source / f'Library/Preferences/{self.old_group}.plist'
        prefs.parent.mkdir(parents=True)
        prefs.write_bytes(plistlib.dumps({'languageCode': 'fr'}))

    def app(self, name, group):
        app = self.home / (name + '.app')
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.weekleft.app', 'WeekleftAppGroup': group}))
        return app

    def test_preserves_exact_data_language_and_originals_and_is_repeatable(self):
        self.assertEqual(migration.migrate(self.old, self.new, self.home), 3)
        target = self.destination / 'Weekleft/snapshot.json'
        self.assertEqual(target.read_bytes(), self.snapshot)
        self.assertEqual((self.source / 'Weekleft/snapshot.json').read_bytes(), self.snapshot)
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        prefs = self.destination / f'Library/Preferences/{self.new_group}.plist'
        self.assertEqual(plistlib.loads(prefs.read_bytes()), {'languageCode': 'fr'})
        self.assertEqual(migration.migrate(self.old, self.new, self.home), 0)

    def test_conflict_prevents_all_writes(self):
        (self.destination / 'Weekleft').mkdir(parents=True)
        target = self.destination / 'Weekleft/activity.json'
        target.write_bytes(b'{"intervals":[],"new":true}')
        with self.assertRaises(ValueError):
            migration.migrate(self.old, self.new, self.home)
        self.assertFalse((self.destination / 'Weekleft/snapshot.json').exists())
        self.assertEqual(target.read_bytes(), b'{"intervals":[],"new":true}')

    def test_corrupt_source_prevents_all_writes(self):
        (self.source / 'Weekleft/activity.json').write_bytes(b'{broken')
        with self.assertRaises(ValueError):
            migration.migrate(self.old, self.new, self.home)
        self.assertFalse(self.destination.exists())

    def test_symlink_cannot_redirect_the_migration(self):
        other = self.home / 'other'
        other.mkdir()
        self.destination.symlink_to(other, target_is_directory=True)
        with self.assertRaises(ValueError):
            migration.migrate(self.old, self.new, self.home)
        self.assertEqual(list(other.iterdir()), [])

    def test_same_group_leaves_existing_data_alone(self):
        self.assertEqual(migration.migrate(self.old, self.old, self.home), 0)


if __name__ == '__main__':
    unittest.main()
