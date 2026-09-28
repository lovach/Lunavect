import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/check-source-hygiene.py'
SPEC = importlib.util.spec_from_file_location('source_hygiene', SCRIPT)
HYGIENE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(HYGIENE)


class SourceHygieneTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for name in ('Sources/WeekleftCore/IDESessionLocation.swift', 'Sources/Weekleft/Resources/IDEConnectors/manifest.json',
                     'Tests/Scripts/test_ide_connectors.py', 'integrations/vscode/routing.js', 'scripts/check.sh'):
            (self.root / name).parent.mkdir(parents=True, exist_ok=True)
            (self.root / name).write_text('x')

    def run_script(self):
        return subprocess.run([sys.executable, str(SCRIPT), '--source-root', str(self.root)], capture_output=True, text=True)

    def test_clean_tree_passes(self):
        self.assertEqual(HYGIENE.conflict_copies(self.root), [])
        self.assertEqual(self.run_script().returncode, 0)

    def test_conflict_copies_of_files_and_directories_are_named(self):
        # The exact copies that broke `swift test` on 2026-09-28.
        for name in ('Sources/WeekleftCore/IDESessionLocation 2.swift', 'Sources/Weekleft/Resources/IDEConnectors/manifest 2.json',
                     'Tests/Scripts/test_ide_connectors 2.py', 'scripts/package-ide-connectors 3.py'):
            (self.root / name).write_text('x')
        (self.root / 'integrations/vscode 2').mkdir()
        (self.root / 'integrations/vscode 2/routing.js').write_text('x')
        found = [str(path) for path in HYGIENE.conflict_copies(self.root)]
        self.assertEqual(found, ['Sources/Weekleft/Resources/IDEConnectors/manifest 2.json',
                                 'Sources/WeekleftCore/IDESessionLocation 2.swift', 'Tests/Scripts/test_ide_connectors 2.py',
                                 'scripts/package-ide-connectors 3.py', 'integrations/vscode 2'])
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertIn('Sources/WeekleftCore/IDESessionLocation 2.swift', result.stderr)

    def test_conflict_copies_that_github_would_run_or_publish_are_named(self):
        # GitHub runs every workflow file and Pages publishes every docs file, so
        # an iCloud copy there acts even though nothing compiles it.
        for name in ('.github/workflows/ci 2.yml', 'docs/faq 2.md', 'design/selected/selection 2.json'):
            (self.root / name).parent.mkdir(parents=True, exist_ok=True)
            (self.root / name).write_text('x')
        (self.root / 'docs/images/showcase 2').mkdir(parents=True)
        found = [str(path) for path in HYGIENE.conflict_copies(self.root)]
        self.assertEqual(found, ['.github/workflows/ci 2.yml', 'docs/faq 2.md', 'docs/images/showcase 2',
                                 'design/selected/selection 2.json'])

    def test_ordinary_names_with_digits_are_not_conflicts(self):
        for name in ('Sources/Weekleft/Resources/claude-2x.png', 'Sources/WeekleftCore/V2Parser.swift', 'Tests/Scripts/fixture_2.json',
                     'Sources/Weekleft/Resources/Icon 1024x1024.png'):
            (self.root / name).write_text('x')
        self.assertEqual(HYGIENE.conflict_copies(self.root), [])

    def test_build_products_and_node_modules_are_ignored(self):
        (self.root / 'integrations/vscode/node_modules/pkg 2').mkdir(parents=True)
        self.assertEqual(HYGIENE.conflict_copies(self.root), [])


if __name__ == '__main__':
    unittest.main()
