"""A failed App Group migration leaves the new container as it found it (R2-P-03).

Copies written by a run that fails are removed again, so a retry after the
previous app saved newer data does not stop installation as a conflict. A copy
that another writer changed meanwhile is never removed. Temporary folders only.
"""
import errno
import importlib.util
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('migration_rollback', Path(__file__).parents[2] / 'scripts/migrate-app-group.py')
migration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(migration)


class GroupMigrationRollbackTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        old_group, new_group = 'group.com.weekleft.shared', 'TESTTEAM01.com.lunavect.shared'
        self.old, self.new = self.app('Old', old_group), self.app('New', new_group)
        containers = self.home / 'Library/Group Containers'
        self.source, self.destination = containers / old_group / 'Weekleft', containers / new_group / 'Weekleft'
        self.source.mkdir(parents=True)
        (self.source / 'snapshot.json').write_bytes(b'{"snapshots":[],"preferences":{"transparency":0.7}}')
        (self.source / 'activity.json').write_bytes(b'{"intervals":[]}')

    def app(self, name, group):
        app = self.home / (name + '.app')
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.weekleft.app', 'WeekleftAppGroup': group}))
        return app

    def fail_second_copy(self, before_failure=lambda: None):
        real, calls = os.fsync, []
        def fsync(descriptor):
            calls.append(descriptor)
            if len(calls) == 2:
                before_failure()
                raise OSError(errno.ENOSPC, 'Synthetic full disk')
            return real(descriptor)
        return patch.object(migration.os, 'fsync', side_effect=fsync)

    def originals(self):
        return {path.name: path.read_bytes() for path in self.source.iterdir()}

    def test_failed_copy_is_undone_and_retry_after_newer_source_completes(self):
        before = self.originals()
        with self.fail_second_copy():
            with self.assertRaises(OSError):
                migration.migrate(self.old, self.new, self.home)
        self.assertEqual(sorted(path.name for path in self.destination.iterdir()), [], 'no partial copy stays behind')
        self.assertEqual(self.originals(), before)
        # The previous app keeps running and saves a newer receipt before the retry.
        newer = b'{"snapshots":[],"preferences":{"transparency":0.4}}'
        (self.source / 'snapshot.json').write_bytes(newer)
        self.assertEqual(migration.migrate(self.old, self.new, self.home), 2)
        self.assertEqual((self.destination / 'snapshot.json').read_bytes(), newer)
        self.assertEqual((self.destination / 'activity.json').read_bytes(), b'{"intervals":[]}')
        self.assertEqual(migration.migrate(self.old, self.new, self.home), 0)

    def test_copy_changed_by_another_writer_is_never_removed(self):
        foreign = b'{"written":"by another writer"}'
        def change_first_copy():
            (self.destination / 'snapshot.json').write_bytes(foreign)
        with self.fail_second_copy(change_first_copy):
            with self.assertRaises(OSError):
                migration.migrate(self.old, self.new, self.home)
        self.assertEqual((self.destination / 'snapshot.json').read_bytes(), foreign)
        self.assertFalse((self.destination / 'activity.json').exists())
        with self.assertRaises(ValueError):
            migration.migrate(self.old, self.new, self.home)
        self.assertEqual((self.destination / 'snapshot.json').read_bytes(), foreign)


if __name__ == '__main__':
    unittest.main()
