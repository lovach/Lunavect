"""verify-hook-helper.py runs the helper through a quoted link (owner decision 18)."""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('verify_hook_helper', ROOT / 'scripts/verify-hook-helper.py')
HOOK = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(HOOK)


class VerifyHookHelperTests(unittest.TestCase):
    def helper(self, root, body):
        path = Path(root) / 'Lunavect.app/Contents/Helpers/LunavectHook'
        path.parent.mkdir(parents=True)
        path.write_text('#!' + sys.executable + '\nimport sys\n' + body)
        path.chmod(0o755)
        return path

    def test_helper_answers_directly_and_through_a_link_with_spaces_and_quotes(self):
        with tempfile.TemporaryDirectory() as root:
            calls = Path(root) / 'calls'
            helper = self.helper(root, f'open({str(calls)!r}, "a").write(repr(sys.argv[1:]) + "\\n")\n'
                                       'assert sys.argv[1] == "--session-hook" and sys.argv[2] in ("claude", "codex")\n'
                                       'assert sys.stdin.read() == "{}"\nprint("{}")\n')
            HOOK.check_invocations(helper)
            lines = calls.read_text().splitlines()
            self.assertEqual(len(lines), 4, 'direct and linked, for both providers')
            self.assertTrue(all("'--session-hook'" in line for line in lines))

    def test_a_helper_that_does_not_answer_fails_the_check(self):
        with tempfile.TemporaryDirectory() as root:
            helper = self.helper(root, 'print("not json")\n')
            with self.assertRaises(SystemExit):
                HOOK.check_invocations(helper)


if __name__ == '__main__':
    unittest.main()
