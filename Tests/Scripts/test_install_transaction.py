"""Real bundle moves/copies in a sandbox; signing/registration are fixture boundaries."""
import json
import os
from pathlib import Path
import plistlib
import platform
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
REGISTER = '/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Support/lsregister'
TOOL = '''
import json, os, sys
from pathlib import Path
name, args = Path(sys.argv[0]).name, sys.argv[1:]
root = Path(os.environ['INSTALL_FIXTURE_HOME'])
with (root / 'trace').open('a') as f: f.write(json.dumps([name, args]) + '\\n')
if name == 'pgrep': sys.exit(1)
if name in ('ps', 'pkill', 'chflags'): sys.exit(0)
# Model the observed macOS invalidation: removing a duplicate extension loses
# its containing-host lookup, even when the installed extension still exists.
lookup = root / 'host-registered'
if name == 'pluginkit' and args[0] == '-r': lookup.unlink(missing_ok=True)
if name == 'lsregister' and args[0] == '-f': lookup.touch()
if name == 'pluginkit' and args[0] == '-a' and not lookup.exists(): sys.exit(43)
dest = str(root / 'Applications/Lunavect.app')
matches = (name == 'codesign' and args[-1] == dest or
           name == 'lsregister' and args == ['-f', dest] or
           name == 'pluginkit' and args == ['-a', dest + '/Contents/PlugIns/LunavectWidget.appex'])
if name == os.environ.get('INSTALL_FIXTURE_FAIL') and matches and not (root / 'failed').exists():
    (root / 'failed').touch(); sys.exit(42)
'''


@unittest.skipUnless(platform.system() == 'Darwin', 'Installer uses macOS tools')
class InstallTransactionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='lunavect-install-fixture-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.bin = self.root / 'bin'; self.bin.mkdir()
        for name in ('pgrep', 'ps', 'pkill', 'chflags', 'codesign', 'lsregister', 'pluginkit'):
            tool = self.bin / name
            tool.write_text('#!' + sys.executable + '\n' + TOOL); tool.chmod(0o755)
        scripts = self.root / 'scripts'; scripts.mkdir()
        source = (ROOT / 'scripts/install.sh').read_text().replace('$HOME', '$INSTALL_FIXTURE_HOME')
        source = source.replace(REGISTER, str(self.bin / 'lsregister')).replace('/usr/bin/pkill', str(self.bin / 'pkill'))
        (scripts / 'install.sh').write_text(source)
        for name in ('verify-product-resources.py', 'verify-hook-helper.py', 'verify-app-groups.py', 'migrate-app-group.py'):
            (scripts / name).write_text('raise SystemExit(0)\n')
        self.dest = self.root / 'Applications/Lunavect.app'
        self.legacy = self.dest.with_name('Weekleft.app')
        self.source = self.root / 'source.app'
        self.bundle(self.source, 'new'); self.bundle(self.dest, 'old')
        self.env = dict(os.environ, INSTALL_FIXTURE_HOME=str(self.root), LUNAVECT_INSTALL_SOURCE=str(self.source),
                        TMPDIR=str(self.root), PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        # Kernel isolation forbids all mutations outside this temporary fixture.
        self.profile = self.root / 'sandbox.sb'
        self.profile.write_text('(version 1) (deny default) (allow process*) (allow sysctl-read) '
                                '(allow file-read*) (allow file-write* (literal "/dev/null") (subpath ' + json.dumps(str(self.root)) + '))')

    def bundle(self, path, marker, identifier='com.weekleft.app'):
        (path / 'Contents').mkdir(parents=True)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier}))
        (path / 'marker').write_text(marker)

    def run_install(self, failure=''):
        return subprocess.run(['/usr/bin/sandbox-exec', '-f', str(self.profile), '/bin/bash',
                               str(self.root / 'scripts/install.sh')], env=dict(self.env, INSTALL_FIXTURE_FAIL=failure),
                              text=True, capture_output=True, timeout=20)

    def test_foreign_legacy_rejected_before_any_side_effect(self):
        self.bundle(self.legacy, 'foreign', 'other.app')
        result = self.run_install()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.dest / 'marker').read_text(), 'old')
        self.assertEqual((self.legacy / 'marker').read_text(), 'foreign')
        self.assertFalse((self.root / 'trace').exists())

    def test_foreign_legacy_symlink_preserved(self):
        self.legacy.symlink_to(self.source)
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assertEqual(self.legacy.readlink(), self.source)
        self.assertEqual((self.dest / 'marker').read_text(), 'old')

    def test_failures_restore_both_original_bundles(self):
        self.bundle(self.legacy, 'legacy')
        for failure in ('codesign', 'lsregister', 'pluginkit'):
            with self.subTest(failure=failure):
                (self.root / 'failed').unlink(missing_ok=True)
                result = self.run_install(failure)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue((self.root / 'failed').exists(), result.stderr)
                self.assertEqual((self.dest / 'marker').read_text(), 'old')
                self.assertFalse(self.legacy.is_symlink())
                self.assertEqual((self.legacy / 'marker').read_text(), 'legacy')
                self.assertEqual(list(self.dest.parent.glob('.Lunavect-install.*')), [])

    def test_success_keeps_legacy_archive_and_compatibility_link(self):
        self.bundle(self.legacy, 'legacy')
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.dest / 'marker').read_text(), 'new')
        self.assertEqual(str(self.legacy.readlink()), 'Lunavect.app')
        archives = list(self.root.glob('Library/Application Support/Weekleft/InstallBackups/*/*.zip'))
        self.assertEqual(len(archives), 1)
        self.assertEqual(subprocess.check_output(['unzip', '-p', str(archives[0]), 'Weekleft.app/marker'], text=True), 'legacy')
        self.assertEqual(list(self.dest.parent.glob('.Lunavect-install.*')), [])

    def test_failed_first_install_removes_new_bundle_and_link(self):
        import shutil
        shutil.rmtree(self.dest)
        result = self.run_install('pluginkit')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / 'failed').exists(), result.stderr)
        self.assertFalse(self.dest.exists())
        self.assertFalse(self.legacy.is_symlink())
