import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/build-manifest.py'


class BuildManifestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.repo = self.base / 'checkout'
        self.repo.mkdir()
        self.run_git('init', '--quiet')
        self.run_git('config', 'user.name', 'Fixture')
        self.run_git('config', 'user.email', 'fixture@example.invalid')
        (self.repo / '.gitignore').write_text('build/\nConfig/Local.xcconfig\n')
        (self.repo / 'source.txt').write_text('original\n')
        self.run_git('add', '.')
        self.run_git('commit', '--quiet', '-m', 'Fixture')
        self.manifest = self.repo / 'build/manifest.json'
        self.product = self.base / 'Lunavect.app'
        (self.product / 'Contents').mkdir(parents=True)
        (self.product / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '130'}))
        (self.product / 'Contents/binary').write_bytes(b'fixture binary\0')
        bin_dir = self.base / 'bin'
        bin_dir.mkdir()
        for name, output in {
            'xcodebuild': 'Xcode 26.6\nBuild version 17G99\nprivate path: /Users/private/test',
            'swift': 'Apple Swift version 6.3.3 (swiftlang-6.3.3.1 clang-1700.0.0)\nTarget: arm64-apple-macosx',
        }.items():
            program = bin_dir / name
            program.write_text('#!/bin/sh\ncat <<\'VERSION\'\n' + output + '\nVERSION\n')
            program.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(bin_dir) + os.pathsep + os.environ.get('PATH', '')}

    def run_git(self, *args, root=None):
        return subprocess.run(['git', '-C', str(root or self.repo), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def run_manifest(self, *args, success=True):
        result = subprocess.run([sys.executable, '-B', str(SCRIPT), *map(str, args)],
                                capture_output=True, text=True, env=self.env)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def begin(self, root=None, output=None):
        self.run_manifest('begin', '--source-root', root or self.repo,
                          '--output', output or self.manifest, '--kind', 'unsigned-check')

    def finalize(self, success=True, root=None, manifest=None):
        return self.run_manifest('finalize', '--source-root', root or self.repo,
                                 '--manifest', manifest or self.manifest, '--app', self.product,
                                 success=success)

    def read(self, path=None):
        return json.loads((path or self.manifest).read_text())

    def test_clean_source_and_product_hashes_without_private_paths(self):
        (self.repo / 'Config').mkdir()
        (self.repo / 'Config/Local.xcconfig').write_text('SECRET_SIGNING_VALUE=do-not-record')
        self.begin()
        (self.repo / 'Config/Local.xcconfig').write_text('SECRET_SIGNING_VALUE=still-not-recorded')
        self.finalize()
        value = self.read()
        self.assertEqual(value['status'], 'complete')
        self.assertEqual(value['kind'], 'unsigned-check')
        self.assertFalse(value['source_before']['dirty'])
        self.assertEqual(value['source_before']['commit'], self.run_git('rev-parse', 'HEAD'))
        self.assertEqual(value['source_integrity'], 'observed-unchanged')
        self.assertEqual(value['product_version'], {'status': 'recorded', 'version': '1.2.3', 'build': '130'})
        self.assertEqual(value['toolchain']['xcode']['version'], '26.6')
        self.assertEqual(value['toolchain']['swift']['version'], '6.3.3')
        entries = {item['path']: item for item in value['artifacts'][0]['entries']}
        self.assertEqual(entries['Contents/binary']['sha256'], hashlib.sha256(b'fixture binary\0').hexdigest())
        serialized = self.manifest.read_text()
        for private in (str(self.base), '/Users/private', 'SECRET_SIGNING_VALUE', 'do-not-record', 'Local.xcconfig'):
            self.assertNotIn(private, serialized)

    def test_dirty_content_is_recorded_and_change_during_build_fails(self):
        (self.repo / 'source.txt').write_text('dirty at start\n')
        self.begin()
        self.assertTrue(self.read()['source_before']['dirty'])
        (self.repo / 'source.txt').write_text('different dirty content\n')
        result = self.finalize(success=False)
        value = self.read()
        self.assertIn('Source changed after begin', result.stderr)
        self.assertEqual(value['status'], 'source-changed')
        self.assertNotEqual(value['source_before']['fingerprint_sha256'], value['source_after']['fingerprint_sha256'])
        self.assertTrue(value['artifacts'])

    def test_unchanged_dirty_source_is_supported(self):
        (self.repo / 'source.txt').write_text('local changes')
        self.begin()
        self.finalize()
        self.assertTrue(self.read()['source_before']['dirty'])
        self.assertEqual(self.read()['status'], 'complete')

    def test_require_clean_rejects_dirty_source_before_creating_manifest(self):
        (self.repo / 'source.txt').write_text('local changes')
        result = self.run_manifest('begin', '--source-root', self.repo, '--output', self.manifest,
                                   '--kind', 'distribution', '--require-clean', success=False)
        self.assertIn('--require-clean requires a clean Git checkout', result.stderr)
        self.assertFalse(self.manifest.exists())
        self.assertFalse(self.manifest.parent.exists())

    def test_require_clean_accepts_fixed_commit_and_is_recorded(self):
        self.run_manifest('begin', '--source-root', self.repo, '--output', self.manifest,
                          '--kind', 'distribution', '--require-clean')
        self.finalize()
        self.assertTrue(self.read()['clean_source_required'])
        self.assertFalse(self.read()['source_before']['dirty'])
        self.assertEqual(self.read()['status'], 'complete')

    def test_untracked_content_changes_are_detected(self):
        (self.repo / 'new-source.txt').write_text('before')
        self.begin()
        (self.repo / 'new-source.txt').write_text('after')
        self.finalize(success=False)
        self.assertEqual(self.read()['source_integrity'], 'changed')

    def test_staging_during_build_is_detected(self):
        (self.repo / 'source.txt').write_text('dirty')
        self.begin()
        self.run_git('add', 'source.txt')
        self.finalize(success=False)
        value = self.read()
        self.assertEqual(value['source_before']['fingerprint_sha256'], value['source_after']['fingerprint_sha256'])
        self.assertNotEqual(value['source_before']['index_sha256'], value['source_after']['index_sha256'])

    def test_missing_artifact_fails_without_marking_complete(self):
        self.begin()
        result = self.run_manifest('finalize', '--source-root', self.repo, '--manifest', self.manifest,
                                   '--artifact', f'dmg={self.base / "missing.dmg"}', success=False)
        self.assertIn('Requested artifact is missing: dmg', result.stderr)
        self.assertEqual(self.read()['status'], 'started')

    def test_render_only_and_symlink_do_not_read_external_content(self):
        render = self.base / 'renders'
        render.mkdir()
        (render / 'state.png').write_bytes(b'fictional image')
        secret = self.base / 'secret'
        secret.write_text('SECRET_CONTENT')
        (render / 'link').symlink_to(secret)
        self.begin()
        self.run_manifest('finalize', '--source-root', self.repo, '--manifest', self.manifest,
                          '--artifact', f'renders={render}')
        value = self.read()
        self.assertEqual(value['product_version']['status'], 'not-run')
        entries = {item['path']: item for item in value['artifacts'][0]['entries']}
        self.assertEqual(entries['link']['type'], 'symlink')
        self.assertEqual(entries['link']['sha256'], hashlib.sha256(os.fsencode(str(secret))).hexdigest())
        self.assertNotIn(str(secret), self.manifest.read_text())
        self.assertNotIn('SECRET_CONTENT', self.manifest.read_text())

    def test_manifest_location_and_duplicate_finalization_are_rejected(self):
        self.run_manifest('begin', '--source-root', self.repo, '--output', self.repo / 'manifest.json', success=False)
        self.run_manifest('begin', '--source-root', self.repo, '--output', self.repo / 'source.txt', success=False)
        self.begin()
        self.run_manifest('begin', '--source-root', self.repo, '--output', self.manifest, success=False)
        self.finalize()
        self.finalize(success=False)

    def test_manifest_cannot_hash_its_own_directory(self):
        self.begin()
        result = self.run_manifest('finalize', '--source-root', self.repo, '--manifest', self.manifest,
                                   '--artifact', f'results={self.manifest.parent}', success=False)
        self.assertIn('must not contain its own manifest', result.stderr)
        self.assertEqual(self.read()['status'], 'started')

    def test_two_worktrees_have_independent_source_checkpoints(self):
        second = self.base / 'second-checkout'
        self.run_git('worktree', 'add', '--quiet', '--detach', str(second), 'HEAD')
        second_manifest = second / 'build/manifest.json'
        self.begin()
        self.begin(root=second, output=second_manifest)
        (self.repo / 'source.txt').write_text('changed in first checkout')
        self.finalize(success=False)
        self.finalize(root=second, manifest=second_manifest)
        self.assertEqual(self.read()['status'], 'source-changed')
        self.assertEqual(self.read(second_manifest)['status'], 'complete')


if __name__ == '__main__':
    unittest.main()
