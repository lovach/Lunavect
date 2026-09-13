import importlib.util
import os
from pathlib import Path
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
        (self.root / '.gitignore').write_text('/output/\n/trace\n/bin/\n')
        self.feed = self.root / 'previous.xml'
        self.feed.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure sparkle:version="103" sparkle:shortVersionString="0.1.0"/></item></channel></rss>')
        self.git('init', '-q'); self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-qm', 'fixture')
        (self.root / 'bin').mkdir()
        tool = self.root / 'bin/xcodebuild'
        tool.write_text('#!/bin/sh\ntouch "$RELEASE_FIXTURE_TRACE"\nexit 42\n'); tool.chmod(0o755)
        self.env = dict(os.environ, LUNAVECT_RELEASE_ROOT=str(self.root / 'output'),
                        RELEASE_FIXTURE_TRACE=str(self.root / 'trace'), PATH=str(tool.parent) + os.pathsep + os.environ['PATH'])

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], stderr=subprocess.STDOUT)

    def archive(self, build='104'):
        result = subprocess.run(['bash', str(self.root / 'scripts/distribute.sh'), 'archive', '0.1.1', build, str(self.feed)],
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
