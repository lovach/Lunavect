"""The scheduled native-render job compares with the newest passed render of the
same suite from an earlier successful run. The GitHub CLI is a recording shim
backed by a JSON fixture; no network or repository access is involved."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FINDER = ROOT / 'scripts/find-render-baseline.py'
SHA = 'a' * 40
GH = r'''
import json, os, shutil, sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse
fixture = json.loads(Path(os.environ['GH_FIXTURE']).read_text())
args = sys.argv[1:]
with open(os.environ['GH_TRACE'], 'a') as trace:
    trace.write(json.dumps(args) + '\n')
if fixture.get('fail'):
    sys.exit('gh: HTTP 503')
if args[0] == 'api':
    url = urlparse(args[1])
    query = {key: values[0] for key, values in parse_qs(url.query).items()}
    parts = url.path.split('/')
    if parts[-1] == 'runs':
        assert query['branch'] == 'main' and query['status'] == 'success', query
        runs = [run for run in fixture['runs'] if run['event'] == query['event']]
        print(json.dumps({'workflow_runs': runs}))
    elif parts[-1] == 'artifacts':
        print(json.dumps({'artifacts': fixture['artifacts'].get(parts[-2], [])}))
    else:
        sys.exit('unexpected endpoint ' + args[1])
elif args[:2] == ['run', 'download']:
    run, name = args[2], args[args.index('--name') + 1]
    target = Path(args[args.index('--dir') + 1])
    shutil.copytree(Path(os.environ['GH_ARTIFACTS']) / run / name, target, dirs_exist_ok=True)
else:
    sys.exit('unexpected gh call')
'''


class RenderBaselineTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='lunavect-render-baseline-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.gh = self.root / 'gh'
        self.gh.write_text('#!' + sys.executable + '\n' + GH)
        self.gh.chmod(0o755)
        self.artifacts = self.root / 'artifacts'
        self.fixture = {'runs': [], 'artifacts': {}}

    def run_entry(self, run_id, event, created, artifacts):
        self.fixture['runs'].append({'id': run_id, 'event': event, 'created_at': created, 'head_branch': 'main'})
        self.fixture['artifacts'][str(run_id)] = [dict(name=name, expired=expired) for name, expired in artifacts]

    def artifact(self, run_id, name, render='passed', suite='smoke'):
        directory = self.artifacts / str(run_id) / name
        (directory / 'images').mkdir(parents=True)
        (directory / 'images/limits-current-ru-light.png').write_bytes(b'png')
        (directory / 'render-report.json').write_text(json.dumps(
            {'render': {'status': render}, 'environment': {'suite': suite}}))

    def find(self, suite='smoke', current=900):
        (self.root / 'fixture.json').write_text(json.dumps(self.fixture))
        output, summary = self.root / 'baseline', self.root / 'summary.md'
        result = subprocess.run(
            [sys.executable, '-B', str(FINDER), '--repository', 'owner/Lunavect', '--workflow', 'ci.yml',
             '--branch', 'main', '--suite', suite, '--arch', 'ARM64', '--exclude-run', str(current),
             '--output', str(output), '--summary', str(summary), '--gh', str(self.gh)],
            env=dict(os.environ, GH_FIXTURE=str(self.root / 'fixture.json'), GH_TRACE=str(self.root / 'trace'),
                     GH_ARTIFACTS=str(self.artifacts)),
            capture_output=True, text=True, timeout=60)
        trace = [json.loads(line) for line in (self.root / 'trace').read_text().splitlines()] if (self.root / 'trace').exists() else []
        return result, output, summary.read_text() if summary.exists() else '', trace

    def test_newest_passed_render_of_the_same_suite_and_architecture_is_downloaded(self):
        name = f'synthetic-native-render-smoke-{SHA}-ARM64-1'
        self.run_entry(900, 'schedule', '2026-10-05T04:17:00Z', [(f'synthetic-native-render-smoke-{SHA}-ARM64-1', False)])
        self.run_entry(800, 'schedule', '2026-09-28T04:17:00Z', [
            (f'synthetic-native-render-legacy-values-{SHA}-ARM64-1', False),
            (f'synthetic-native-render-smoke-{SHA}-X64-1', False),
            (f'unsigned-check-{SHA}-ARM64-1', False)])
        self.run_entry(700, 'workflow_dispatch', '2026-09-25T10:00:00Z', [(name, False)])
        self.run_entry(600, 'schedule', '2026-09-21T04:17:00Z', [(name, False)])
        self.artifact(700, name); self.artifact(600, name)
        result, output, summary, trace = self.find()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(output))
        self.assertTrue((output / 'render-report.json').is_file())
        self.assertTrue((output / 'images/limits-current-ru-light.png').is_file())
        self.assertIn(['run', 'download', '700', '--repo', 'owner/Lunavect', '--name', name, '--dir'], [call[:8] for call in trace])
        self.assertNotIn('900', [call[2] for call in trace if call[:2] == ['run', 'download']])
        self.assertIn('run 700', summary)
        # Only successful schedule and manual runs on the default branch are queried.
        queries = [call[1] for call in trace if call[0] == 'api' and call[1].split('?')[0].endswith('/runs')]
        self.assertEqual(sorted(query.split('event=')[1].split('&')[0] for query in queries), ['schedule', 'workflow_dispatch'])

    def test_expired_failed_or_mismatched_renders_are_skipped(self):
        name = f'synthetic-native-render-smoke-{SHA}-ARM64-1'
        self.run_entry(700, 'schedule', '2026-09-28T04:17:00Z', [(name, True)])
        self.run_entry(650, 'schedule', '2026-09-24T04:17:00Z', [(name, False)])
        self.run_entry(600, 'schedule', '2026-09-21T04:17:00Z', [(name, False)])
        self.run_entry(550, 'schedule', '2026-09-14T04:17:00Z', [(name, False)])
        self.artifact(650, name, render='failed'); self.artifact(600, name, suite='legacy-values'); self.artifact(550, name)
        result, output, summary, trace = self.find()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(output))
        self.assertEqual([call[2] for call in trace if call[:2] == ['run', 'download']], ['650', '600', '550'])
        self.assertIn('run 550', summary)

    def test_latest_attempt_of_a_rerun_is_preferred(self):
        first, second = (f'synthetic-native-render-smoke-{SHA}-ARM64-{attempt}' for attempt in (1, 2))
        self.run_entry(700, 'schedule', '2026-09-28T04:17:00Z', [(first, False), (second, False)])
        self.artifact(700, first); self.artifact(700, second)
        result, _, _, trace = self.find()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[6] for call in trace if call[:2] == ['run', 'download']], [second])

    def test_missing_baseline_lets_the_render_run_without_comparison(self):
        self.run_entry(900, 'schedule', '2026-10-05T04:17:00Z', [(f'synthetic-native-render-smoke-{SHA}-ARM64-1', False)])
        result, output, summary, _ = self.find()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertFalse(output.exists())
        self.assertIn('No passed baseline', summary)

    def test_lookup_failure_is_reported_without_failing_the_render(self):
        self.fixture['fail'] = True
        result, output, summary, _ = self.find()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertFalse(output.exists())
        self.assertIn('::warning::', result.stderr)
        self.assertIn('lookup failed', summary)

    def test_existing_output_is_never_reused(self):
        (self.root / 'baseline').mkdir()
        result, _, _, trace = self.find()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(trace, [])


if __name__ == '__main__':
    unittest.main()
