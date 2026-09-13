import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('project_parity', ROOT / 'scripts/check-project-parity.py')
PARITY = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(PARITY)


@unittest.skipUnless(shutil.which('xcodegen'), 'XcodeGen is optional locally; pinned in CI')
class ProjectParityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        shutil.copyfile(ROOT / 'project.yml', self.root / 'project.yml')
        for name in ('Sources', 'Widget', 'Config', 'Weekleft.xcodeproj'):
            shutil.copytree(ROOT / name, self.root / name, ignore=shutil.ignore_patterns('Local.xcconfig'))

    def test_current_project_matches_without_rewriting_source(self):
        project = self.root / 'Weekleft.xcodeproj/project.pbxproj'
        before = project.read_bytes()
        PARITY.verify(self.root)
        self.assertEqual(project.read_bytes(), before)

    def test_manual_project_or_scheme_drift_is_detected_and_preserved(self):
        for relative in ('project.pbxproj', 'xcshareddata/xcschemes/Weekleft.xcscheme'):
            path = self.root / 'Weekleft.xcodeproj' / relative
            original = path.read_bytes()
            changed = original + b'\n<!-- deliberate fixture drift -->\n'
            path.write_bytes(changed)
            with self.assertRaisesRegex(ValueError, 'differs from project.yml'):
                PARITY.verify(self.root)
            self.assertEqual(path.read_bytes(), changed)
            path.write_bytes(original)
