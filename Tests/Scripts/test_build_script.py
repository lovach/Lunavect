"""build.sh project generation with fake tools; stops at the fake xcodebuild."""
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = '''
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
with open(os.environ['BUILD_FIXTURE_TRACE'], 'a') as trace: trace.write(json.dumps([name, sys.argv[1:]]) + '\\n')
if name == 'xcodegen' and sys.argv[1:] == ['--version']: print('Version: ' + os.environ['BUILD_FIXTURE_XCODEGEN'])
sys.exit(42 if name == 'xcodebuild' else 0)
'''


@unittest.skipUnless(platform.system() == 'Darwin', 'build.sh uses macOS tools')
class BuildScriptTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='lunavect-build-fixture-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / 'scripts').mkdir()
        for name in ('build.sh', 'check-project-parity.py'):
            shutil.copy(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        (self.root / 'project.yml').write_text('    CURRENT_PROJECT_VERSION: 100\n')
        (self.root / 'Signing.xcconfig').write_text('')
        self.bin = self.root / 'bin'; self.bin.mkdir()
        for name in ('xcodegen', 'xcodebuild'):
            tool = self.bin / name
            tool.write_text('#!' + sys.executable + '\n' + TOOL); tool.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.root / 'home'), WEEKLEFT_DERIVED_DATA=str(self.root / 'derived'),
                        WEEKLEFT_SIGNING_CONFIG=str(self.root / 'Signing.xcconfig'), BUILD_FIXTURE_TRACE=str(self.root / 'trace'),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        # Kernel isolation: the script may write only inside this fixture.
        self.profile = self.root / 'sandbox.sb'
        self.profile.write_text('(version 1) (deny default) (allow process*) (allow sysctl-read) (allow file-read*) '
                                '(allow file-write* (literal "/dev/null") (subpath ' + json.dumps(str(self.root)) + '))')

    def build(self, xcodegen_version):
        result = subprocess.run(['/usr/bin/sandbox-exec', '-f', str(self.profile), '/bin/bash', str(self.root / 'scripts/build.sh')],
                                env=dict(self.env, BUILD_FIXTURE_XCODEGEN=xcodegen_version), text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 42, result.stderr)
        calls = [json.loads(line) for line in (self.root / 'trace').read_text().splitlines()]
        self.assertEqual(calls[-1][0], 'xcodebuild', 'The fake build must be the last step reached')
        return result, calls

    def test_other_xcodegen_version_leaves_tracked_project_alone(self):
        result, calls = self.build('2.45.1')
        self.assertNotIn(['xcodegen', ['generate']], calls)
        self.assertIn('XcodeGen 2.46.0 is required', result.stderr)

    def test_pinned_xcodegen_regenerates_project(self):
        result, calls = self.build('2.46.0')
        self.assertIn(['xcodegen', ['generate']], calls)
        self.assertNotIn('Skipping project generation', result.stderr)
