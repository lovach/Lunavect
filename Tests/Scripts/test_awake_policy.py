import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('awake_policy', ROOT / 'scripts/verify-awake-policy.py')
POLICY = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(POLICY)


class AwakePolicyTests(unittest.TestCase):
    def test_public_packaging_refuses_local_helper_and_accepts_distribution_probe(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'Lunavect.app'
            helper = app / 'Contents/Library/LaunchServices/LunavectAwakeHelper'
            helper.parent.mkdir(parents=True)
            for mode in ('development', 'developer-id'):
                helper.write_text('#!' + sys.executable + '\nimport sys\nassert sys.argv[1:] == ["--signing-policy"]\nprint(' + repr(mode) + ')\n')
                helper.chmod(0o755)
                POLICY.verify(app, mode)
                if mode == 'development':
                    with self.assertRaisesRegex(ValueError, 'expected developer-id'):
                        POLICY.verify(app, 'developer-id')
