import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('release_gate', ROOT / 'scripts/release-preflight.py')
GATE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(GATE)


class ReleasePreflightTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'scripts').mkdir()
        for name in ('distribute.sh', 'release-preflight.py', 'build-manifest.py'):
            shutil.copy(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        # Product checks are fixture boundaries; FIXTURE_RESOURCES_EXIT fails the resource check.
        (self.root / 'scripts/verify-product-resources.py').write_text(
            'import os\nraise SystemExit(int(os.environ.get("FIXTURE_RESOURCES_EXIT", "0")))\n')
        (self.root / 'scripts/verify-awake-policy.py').write_text('raise SystemExit(0)\n')
        (self.root / '.gitignore').write_text('/output/\n/trace\n/bin/\n/home/\n')
        self.feed = self.root / 'previous.xml'
        self.feed.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure sparkle:version="103" sparkle:shortVersionString="0.1.0"/></item></channel></rss>')
        self.git('init', '-q'); self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-qm', 'fixture')
        (self.root / 'bin').mkdir()
        tool = self.root / 'bin/xcodebuild'
        tool.write_text('#!/bin/sh\ntouch "$RELEASE_FIXTURE_TRACE"\nexit 42\n'); tool.chmod(0o755)
        # A private home keeps the owner's installed app out of these fixtures.
        self.home = self.root / 'home'
        self.env = dict(os.environ, HOME=str(self.home), LUNAVECT_RELEASE_ROOT=str(self.root / 'output'),
                        RELEASE_FIXTURE_TRACE=str(self.root / 'trace'), PATH=str(tool.parent) + os.pathsep + os.environ['PATH'])

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], stderr=subprocess.STDOUT)

    def installed(self, build, identifier='com.weekleft.app', app=None):
        app = app or self.home / 'Applications/Lunavect.app'
        (app / 'Contents').mkdir(parents=True, exist_ok=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier, 'CFBundleVersion': build}))
        return app

    def archive(self, build='104', version='0.1.1'):
        result = subprocess.run(['bash', str(self.root / 'scripts/distribute.sh'), 'archive', version, build, str(self.feed)],
                                env=self.env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'trace').exists(), 'Compiler reached before rejection')
        return result.stderr

    def test_dirty_source_fails_before_build(self):
        (self.root / 'new-source').write_text('dirty')
        self.assertIn('clean Git checkout', self.archive())

    def test_existing_tag_fails_before_build(self):
        self.git('tag', 'v0.1.1')
        self.assertIn('tag already exists', self.archive())

    def test_equal_and_older_builds_fail_before_build(self):
        for build in ('103', '102'):
            self.assertIn('exceed every build', self.archive(build))

    def test_release_build_must_exceed_installed_local_build(self):
        # build.sh gave the owner's installed copy 182 while the feed ended at 181.
        app = self.installed('182')
        for build in ('181', '182'):
            with self.assertRaisesRegex(ValueError, 'installed local build 182'):
                GATE.validate_installed(build, [app])
        GATE.validate_installed('183', [app, self.root / 'missing/Lunavect.app'])
        GATE.validate_installed('100', [self.installed('500', 'other.app', self.root / 'foreign/Lunavect.app')])
        for content in (b'<plist><dict>', b'garbage'):
            (app / 'Contents/Info.plist').write_bytes(content)
            with self.assertRaisesRegex(ValueError, 'Cannot read the build'):
                GATE.validate_installed('183', [app])
        self.installed('182.1')
        with self.assertRaisesRegex(ValueError, 'no numeric build'):
            GATE.validate_installed('183', [app])

    def test_archive_rejects_release_build_at_installed_local_build(self):
        self.feed.write_text(self.feed.read_text().replace('103', '181').replace('0.1.0', '0.1.9'))
        self.git('commit', '-qam', 'published 181')
        self.installed('182')
        self.assertIn('installed local build 182', self.archive('182', '0.1.10'))

    def fake_xcode(self):
        # Records each invocation; creates an archived app, and fails every other action
        # so distribute.sh stops before its registration cleanup touches the system.
        (self.root / 'bin/xcodebuild').write_text('#!' + sys.executable + '''
import os, pathlib, plistlib, sys
args = sys.argv[1:]
with open(os.environ['RELEASE_FIXTURE_TRACE'], 'a') as trace: trace.write(' '.join(args) + '\\n')
if not args or args[-1] != 'archive': sys.exit(42)
value = lambda name: next(item.split('=', 1)[1] for item in args if item.startswith(name + '='))
app = pathlib.Path(args[args.index('-archivePath') + 1]) / 'Products/Applications/Lunavect.app/Contents'
app.mkdir(parents=True)
(app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': value('MARKETING_VERSION'),
                                                 'CFBundleVersion': value('CURRENT_PROJECT_VERSION')}))
''')

    def distribute(self, action, **env):
        return subprocess.run(['bash', str(self.root / 'scripts/distribute.sh'), action, '0.1.1', '104']
                              + ([str(self.feed)] if action == 'archive' else []),
                              env=dict(self.env, **env), text=True, capture_output=True)

    def traced(self, action):
        trace = self.root / 'trace'
        return any(action in line.split() for line in (trace.read_text().splitlines() if trace.exists() else []))

    def test_failed_archive_checks_block_submit_and_export(self):
        self.fake_xcode()
        result = self.distribute('archive', FIXTURE_RESOURCES_EXIT='1')
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.traced('archive'), result.stderr)
        manifest = self.root / 'output/Lunavect-0.1.1-104-manifest.json'
        self.assertEqual(json.loads(manifest.read_text())['status'], 'started')
        for action, xcode_action in (('submit', '-exportArchive'), ('export', '-exportNotarizedApp')):
            result = self.distribute(action)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Manifest is not complete', result.stderr)
            self.assertFalse(self.traced(xcode_action), action + ' reached Xcode with an unverified archive')

    def test_export_requires_the_app_the_manifest_verified(self):
        self.fake_xcode()
        archive = self.root / 'output/Lunavect-0.1.1-104.xcarchive'
        app = archive / 'Products/Applications/Lunavect.app'
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.1.1', 'CFBundleVersion': '104'}))
        manifest = self.root / 'output/Lunavect-0.1.1-104-manifest.json'
        tool = [sys.executable, str(self.root / 'scripts/build-manifest.py')]
        subprocess.run(tool + ['begin', '--source-root', str(self.root), '--kind', 'distribution', '--output', str(manifest)],
                       env=self.env, check=True, capture_output=True)
        subprocess.run(tool + ['finalize', '--source-root', str(self.root), '--manifest', str(manifest), '--app', str(app)],
                       env=self.env, check=True, capture_output=True)
        result = self.distribute('export')
        self.assertTrue(self.traced('-exportNotarizedApp'), result.stderr)
        (self.root / 'trace').unlink()
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.1.1', 'CFBundleVersion': '104', 'Changed': True}))
        result = self.distribute('export')
        self.assertIn('App differs from the one the manifest recorded', result.stderr)
        self.assertFalse(self.traced('-exportNotarizedApp'))

    def test_new_release_accepts_clean_tree_and_higher_build(self):
        GATE.validate_previous('0.1.1', '104', self.feed)
        GATE.validate_source(self.root, '0.1.1')

    def test_all_appcast_entries_and_modern_element_form_are_checked(self):
        self.feed.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
                             '<item><sparkle:version>200</sparkle:version><sparkle:shortVersionString>0.1.5</sparkle:shortVersionString><enclosure/></item>'
                             '<item><enclosure sparkle:version="103" sparkle:shortVersionString="0.1.0"/></item></channel></rss>')
        with self.assertRaisesRegex(ValueError, 'exceed every build'):
            GATE.validate_previous('0.2.0', '104', self.feed)
        GATE.validate_previous('0.2.0', '201', self.feed)
        for xml in ('<rss/>', '<rss><channel><item><enclosure/></item></channel></rss>'):
            self.feed.write_text(xml)
            with self.assertRaises(ValueError): GATE.validate_previous('0.2.0', '201', self.feed)

    def test_marketing_version_reuse_and_downgrade_fail_even_with_higher_build(self):
        for version in ('0.0.9', '0.1.0'):
            with self.assertRaisesRegex(ValueError, 'marketing version must exceed'):
                GATE.validate_previous(version, '104', self.feed)
        # Comparison is numerical, so 0.1.10 is newer than 0.1.9.
        self.feed.write_text(self.feed.read_text().replace('0.1.0', '0.1.9'))
        GATE.validate_previous('0.1.10', '104', self.feed)

    def test_missing_and_malformed_previous_marketing_versions_fail_closed(self):
        original = self.feed.read_text()
        for replacement in ('', ' sparkle:shortVersionString="garbage"', ' sparkle:shortVersionString="0..1"'):
            self.feed.write_text(original.replace(' sparkle:shortVersionString="0.1.0"', replacement))
            with self.assertRaisesRegex(ValueError, 'marketing version'):
                GATE.validate_previous('0.2.0', '104', self.feed)

    def test_shallow_checkout_is_not_release_tag_evidence(self):
        clone = self.root / 'output/shallow'
        subprocess.run(['git', 'clone', '--quiet', '--depth', '1', self.root.as_uri(), str(clone)], check=True)
        with self.assertRaisesRegex(ValueError, 'shallow history'):
            GATE.validate_source(clone, '0.1.1')

    def test_distribution_manifest_rejects_dirty_even_without_flag(self):
        (self.root / 'dirty').touch()
        result = subprocess.run([sys.executable, str(self.root / 'scripts/build-manifest.py'), 'begin',
                                 '--source-root', str(self.root), '--output', str(self.root / 'output/manifest.json'),
                                 '--kind', 'distribution'], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('clean Git checkout', result.stderr)
        self.assertFalse((self.root / 'output/manifest.json').exists())
