"""Exercise distribution cleanup with an invalidating registration service fixture.

The cleanup block of distribute.sh runs as a real Python process. Launch Services,
PlugInKit and the process list are recording shims selected through
LUNAVECT_LSREGISTER, LUNAVECT_PLUGINKIT and PATH, so no case can reach the
host registry, and HOME/LUNAVECT_INSTALLED_APPS keep installed copies private.
"""
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MARKER = 'python3 - "$ARCHIVE" "$OUTPUT" "$BUILD" "$ROOT" <<\'PY\'\n'
SHIM = r'''
import json, os, sys
from pathlib import Path
name, args = Path(sys.argv[0]).name, sys.argv[1:]
root = Path(os.environ['FIXTURE_ROOT'])
with (root / 'trace').open('a') as trace:
    trace.write(json.dumps([name] + args) + '\n')
state_path = root / 'state.json'
state = json.loads(state_path.read_text())
def save():
    state_path.write_text(json.dumps(state))
if name == 'ps':
    print(os.environ.get('FIXTURE_PROCESSES', ''))
elif name == 'lsregister' and args == ['-dump']:
    for path in state['registered']:
        print(f'path: {path} (0x1a2b)')
elif name == 'lsregister' and args[0] == '-u':
    # Removing any same-ID copy invalidates the installed host's lookup.
    state['valid'] = False
    state['unregister_attempts'] += 1
    save()
    if state['unregister_attempts'] <= int(os.environ.get('FIXTURE_UNREGISTER_FAILURES', '0')):
        sys.exit('failed to scan: -10814')
    state['registered'] = [path for path in state['registered'] if path != args[1]]
    save()
elif name == 'lsregister' and args[0] == '-f':
    if os.environ.get('FIXTURE_FAIL_REGISTER'):
        sys.exit(42)
    state['valid'] = True
    save()
elif name == 'pluginkit' and args[0] == '-r':
    state['valid'] = False
    save()
elif name == 'pluginkit' and args[0] == '-a':
    if not state['valid']:
        sys.exit('Extension registered without its host')
else:
    sys.exit('Unexpected tool call: ' + ' '.join([name] + args))
'''


def cleanup_source():
    text = (ROOT / 'scripts/distribute.sh').read_text()
    assert MARKER in text, 'distribute.sh cleanup block moved; update this fixture'
    return text.split(MARKER, 1)[1].split('\nPY\n', 1)[0]


class DistributionRegistrationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='lunavect-distribution-fixture-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ('lsregister', 'pluginkit', 'ps'):
            tool = self.bin / name
            tool.write_text('#!' + sys.executable + '\n' + SHIM)
            tool.chmod(0o755)
        self.home = self.root / 'home'
        self.archive, self.output = self.root / 'Archive.xcarchive', self.root / 'output'
        self.installed = self.home / 'Applications/Lunavect.app'
        self.system = self.root / 'global/Lunavect.app'
        self.exported = self.archive / 'Products/Applications/Lunavect.app'
        self.bundle(self.exported)

    def bundle(self, app, identifier='com.weekleft.app', widget_version='163'):
        for bundle, bundle_id, build in [(app, identifier, '163'),
                                         (app / 'Contents/PlugIns/LunavectWidget.appex', 'com.weekleft.app.widget', widget_version)]:
            info = bundle / 'Contents/Info.plist'
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle_id, 'CFBundleVersion': build}))

    def cleanup(self, installed=None, processes='', **fixture):
        (self.root / 'state.json').write_text(json.dumps(
            {'registered': [str(self.exported)], 'valid': True, 'unregister_attempts': 0}))
        (self.root / 'trace').unlink(missing_ok=True)
        installed = [self.installed, self.system] if installed is None else installed
        environment = dict(os.environ, HOME=str(self.home), FIXTURE_ROOT=str(self.root), FIXTURE_PROCESSES=processes,
                           PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                           LUNAVECT_LSREGISTER=str(self.bin / 'lsregister'), LUNAVECT_PLUGINKIT=str(self.bin / 'pluginkit'),
                           LUNAVECT_INSTALLED_APPS=os.pathsep.join(map(str, installed)), **fixture)
        result = subprocess.run([sys.executable, '-B', '-', str(self.archive), str(self.output), '163', str(ROOT)],
                                input=cleanup_source(), env=environment, capture_output=True, text=True, timeout=30)
        trace = [json.loads(line) for line in (self.root / 'trace').read_text().splitlines()]
        state = json.loads((self.root / 'state.json').read_text())
        return result, [call for call in trace if call[0] != 'ps'], state

    def test_cleanup_restores_installed_host_after_every_temporary_removal(self):
        self.bundle(self.installed)
        result, trace, state = self.cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(['lsregister', '-u', str(self.exported)], trace)
        self.assertIn(['pluginkit', '-r', str(self.exported / 'Contents/PlugIns/LunavectWidget.appex')], trace)
        self.assertEqual(trace[-2:], [['lsregister', '-f', str(self.installed)],
                                      ['pluginkit', '-a', str(self.installed / 'Contents/PlugIns/LunavectWidget.appex')]])
        self.assertTrue(state['valid'])
        self.assertEqual(state['registered'], [])

    def test_foreign_or_mismatched_installed_bundle_is_not_registered(self):
        for kwargs in (dict(identifier='other.app'), dict(widget_version='162')):
            with self.subTest(**kwargs):
                shutil.rmtree(self.installed, ignore_errors=True)
                self.bundle(self.installed, **kwargs)
                result, trace, _ = self.cleanup()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse([call for call in trace if call[1] in ('-f', '-a')], trace)

    def test_failed_host_registration_is_reported(self):
        self.bundle(self.installed)
        result, trace, _ = self.cleanup(FIXTURE_FAIL_REGISTER='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(trace[-1], ['lsregister', '-f', str(self.installed)])

    def test_transient_unregister_failure_is_retried(self):
        self.bundle(self.installed)
        result, trace, state = self.cleanup(FIXTURE_UNREGISTER_FAILURES='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call for call in trace if call[:2] == ['lsregister', '-u']],
                         [['lsregister', '-u', str(self.exported)]] * 2)
        self.assertEqual(trace[-2][:2], ['lsregister', '-f'])
        self.assertTrue(state['valid'])

    def test_persistent_unregister_failure_still_restores_installed_host(self):
        self.bundle(self.installed)
        result, trace, state = self.cleanup(FIXTURE_UNREGISTER_FAILURES='3')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(trace[-2:], [['lsregister', '-f', str(self.installed)],
                                      ['pluginkit', '-a', str(self.installed / 'Contents/PlugIns/LunavectWidget.appex')]])
        self.assertTrue(state['valid'])

    def test_two_installed_copies_restore_only_the_running_one(self):
        self.bundle(self.installed); self.bundle(self.system)
        for running, other in ((self.system, self.installed), (self.installed, self.system)):
            with self.subTest(running=running.parent.name):
                result, trace, state = self.cleanup(processes='  501 ' + str(running / 'Contents/MacOS/Lunavect'))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(trace[-2:], [['lsregister', '-f', str(running)],
                                              ['pluginkit', '-a', str(running / 'Contents/PlugIns/LunavectWidget.appex')]])
                self.assertFalse([call for call in trace if str(other) in call[-1]], trace)
                self.assertIn('Two Lunavect copies', result.stderr)
                self.assertTrue(state['valid'])

    def test_two_installed_copies_without_a_running_one_use_the_documented_order(self):
        self.bundle(self.installed); self.bundle(self.system)
        result, trace, _ = self.cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace[-2][1:], ['-f', str(self.installed)])
        self.assertFalse([call for call in trace if str(self.system) in call[-1]], trace)
        self.assertIn('neither is running', result.stderr)


if __name__ == '__main__':
    unittest.main()
