"""Exercise the check runner with real reports and disposable tool-boundary fixtures."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
REPORTER = ROOT / 'scripts/check-report.py'
STAGES = (
    'source_checkpoint', 'python_tests', 'swift_tests', 'widget_probe_build',
    'widget_fallback', 'widget_private_abi', 'unsigned_build', 'hook_helper',
    'product_resources', 'intent_resources', 'build_provenance',
)
MANUAL = ('native_render', 'live_clients', 'desktop_widget', 'signed_distribution',
          'supported_macos_hardware')

# Only compilers/client test entry points are replaced. The shell runner, stage
# reporter, source checkpoint, manifest finalization and Python unittest are real.
TOOL = r'''
import json
import os
from pathlib import Path
import plistlib
import sys
import time

name, args = Path(sys.argv[0]).name, sys.argv[1:]
event = {'tool': name, 'args': args,
         'opt_in': sorted(key for key in os.environ if key.startswith('LUNAVECT_'))}
trace = Path(os.environ['CHECK_FIXTURE_TRACE'])
with trace.open('a') as stream:
    stream.write(json.dumps(event) + '\n')
intent = name == 'swift' and args == ['test', '--jobs', '2', '--filter', 'ActivityWidgetIntentLocalizationTests.testBuiltAppAndWidgetContainResolvableIntentMetadata']
if intent:
    assert event['opt_in'] == ['LUNAVECT_INTENT_BUNDLE_PATHS']
elif event['opt_in']:
    raise SystemExit('Inherited opt-in flag reached a check command')
failure = os.environ.get('CHECK_FIXTURE_FAIL')
if name == 'swift':
    if args == ['--version']:
        print('Apple Swift version 6.3.3 (swiftlang-6.3.3.1 clang-1700.0.0)')
    elif intent:
        bundles = [Path(value) for value in json.loads(os.environ['LUNAVECT_INTENT_BUNDLE_PATHS'])]
        assert len(bundles) == 2
        assert bundles[0].name == 'Lunavect.app'
        assert bundles[1] == bundles[0] / 'Contents/PlugIns/LunavectWidget.appex'
        assert all((bundle / 'Contents/Info.plist').is_file() for bundle in bundles), 'Products removed before intent check'
        if failure == 'intent_resources':
            print('Executed 1 test, with 1 failure (0 unexpected) in 0.001 seconds')
            raise SystemExit(1)
        print('Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds')
    else:
        assert args == ['test', '--jobs', '2'], args
        if failure == 'swift_tests':
            print("Test Case '-[FixtureTests testGood]' passed (0.001 seconds).")
            print("Test Case '-[FixtureTests testBad]' failed (0.001 seconds).")
            print('Executed 2 tests, with 5 failures (0 unexpected) in 0.002 seconds')
            raise SystemExit(1)
        print("Test Case '-[FixtureTests testGood]' passed (0.001 seconds).")
        print("Test Case '-[FixtureTests testOptional]' skipped (0.001 seconds).")
        print('Executed 2 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.002 seconds')
elif name == 'clang':
    output = Path(args[args.index('-o') + 1])
    output.write_text(Path(sys.argv[0]).read_text())
    output.chmod(0o755)
elif name == 'background-check':
    if args == ['--incompatible']:
        print('Standard background fallback verified in fixture')
    else:
        assert not args, args
        raise SystemExit(int(os.environ.get('CHECK_FIXTURE_ABI_STATUS', '77')))
elif name == 'xcodebuild':
    if args == ['-version']:
        print('Xcode 26.6\nBuild version 17G99')
    else:
        derived = Path(args[args.index('-derivedDataPath') + 1])
        assert 'REGISTER_APP_WITH_LAUNCH_SERVICES=NO' in args
        assert 'CODE_SIGNING_ALLOWED=NO' in args
        derived.mkdir(parents=True)
        barrier = os.environ.get('CHECK_FIXTURE_BARRIER')
        if barrier:
            ready = Path(barrier)
            (ready / os.environ['CHECK_FIXTURE_ID']).write_text(str(derived))
            deadline = time.monotonic() + 15
            while len(list(ready.iterdir())) < 2:
                if time.monotonic() >= deadline:
                    raise SystemExit('Concurrent fixture did not reach the build barrier')
                time.sleep(0.01)
        app = derived / 'Build/Products/Release/Lunavect.app/Contents'
        app.mkdir(parents=True)
        (app / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'test.lunavect.check-fixture',
            'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '130'}))
        (app / 'fixture-binary').write_bytes(b'fixture-app\n')
        widget = app / 'PlugIns/LunavectWidget.appex/Contents'
        widget.mkdir(parents=True)
        (widget / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'test.lunavect.check-fixture.widget'}))
        if failure == 'unsigned_build':
            raise SystemExit(42)
else:
    raise SystemExit('Unexpected tool boundary: ' + name)
'''


class CheckRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='lunavect-check-tests-')
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        tool = '#!' + sys.executable + '\n' + textwrap.dedent(TOOL)
        for name in ('swift', 'clang', 'xcodebuild'):
            path = self.bin / name
            path.write_text(tool)
            path.chmod(0o755)
        self.runtime = self.base / 'runtime'
        self.runtime.mkdir()
        self.forbidden = self.base / 'forbidden-system-actions'
        # The DEBUG trap blocks even the old absolute lsregister path before it
        # could execute. This is a fixture safety guard, not a source-text test.
        guard = self.base / 'shell-guard.sh'
        guard.write_text(textwrap.dedent('''\
            set -T
            trap 'case "$BASH_COMMAND" in *pluginkit*|*lsregister*) printf "blocked\\n" >> "$CHECK_FIXTURE_FORBIDDEN"; exit 99;; esac' DEBUG
        '''))
        self.env = {
            **os.environ,
            'PATH': str(self.bin) + os.pathsep + os.environ.get('PATH', ''),
            'TMPDIR': str(self.runtime),
            'BASH_ENV': str(guard),
            'CHECK_FIXTURE_FORBIDDEN': str(self.forbidden),
            'LUNAVECT_RENDER_ACTIVITY': '/never-render-fixture',
            'LUNAVECT_RELEASE_SCREENSHOTS': '/never-export-fixture',
            'LUNAVECT_TEST_LIVE_CLIENT': '1',
        }
        self.env.pop('WEEKLEFT_CHECK_DERIVED_DATA', None)
        self.env.pop('WEEKLEFT_CHECK_RESULTS', None)

    def fixture(self, name):
        repo = self.base / name
        (repo / 'scripts').mkdir(parents=True)
        (repo / 'Tests/Scripts').mkdir(parents=True)
        for script in ('check.sh', 'check-report.py', 'build-manifest.py'):
            shutil.copy2(ROOT / 'scripts' / script, repo / 'scripts' / script)
        for script in ('verify-hook-helper.py', 'verify-product-resources.py'):
            (repo / 'scripts' / script).write_text(textwrap.dedent('''\
                import os
                from pathlib import Path
                import sys
                assert not any(key.startswith('LUNAVECT_') for key in os.environ)
                assert (Path(sys.argv[1]) / 'Contents/Info.plist').is_file()
            '''))
        (repo / 'Tests/Scripts/test_fixture.py').write_text(textwrap.dedent('''\
            import os
            import unittest
            class FixtureTests(unittest.TestCase):
                def test_default_check_has_no_opt_in_environment(self):
                    self.assertFalse([key for key in os.environ if key.startswith('LUNAVECT_')])
                @unittest.skip('An explicit fixture opt-in is unavailable')
                def test_optional(self):
                    self.fail('The skipped fixture must not run')
        '''))
        (repo / '.gitignore').write_text('build/\n__pycache__/\n')
        (repo / 'fixture-source.txt').write_text('stable synthetic source\n')
        for args in (('init', '--quiet'), ('add', '.'),
                     ('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                      '-c', 'commit.gpgSign=false', 'commit', '--quiet', '-m', 'Check fixture')):
            subprocess.run(['git', '-C', str(repo), *args], check=True,
                           capture_output=True, text=True)
        return repo

    def run_check(self, repo, **overrides):
        trace = self.base / (repo.name + '-trace.jsonl')
        env = {**self.env, 'CHECK_FIXTURE_ID': repo.name,
               'CHECK_FIXTURE_TRACE': str(trace), **overrides}
        process = subprocess.run(['/bin/bash', str(repo / 'scripts/check.sh')],
                                 cwd=self.base, env=env, capture_output=True,
                                 text=True, timeout=40)
        reports = list((repo / 'build/check-results').glob('run.*/check-results.json'))
        self.assertEqual(len(reports), 1, process.stdout + process.stderr)
        report_path = reports[0]
        return process, json.loads(report_path.read_text()), report_path, trace

    def read_trace(self, path):
        return [json.loads(line) for line in path.read_text().splitlines()]

    def assert_manual_not_run(self, report):
        for stage in MANUAL:
            self.assertEqual(report['checks'][stage]['status'], 'not-run', stage)

    def assert_success_evidence(self, repo, report, report_path):
        self.assertEqual(report['status'], 'passed')
        self.assertEqual(report['exit_code'], 0)
        for stage in STAGES:
            expected = 'skipped' if stage == 'widget_private_abi' else 'passed'
            self.assertEqual(report['checks'][stage]['status'], expected, stage)
        for stage in ('python_tests', 'swift_tests'):
            self.assertEqual(report['checks'][stage]['counts'],
                             {'total': 2, 'passed': 1, 'skipped': 1, 'failures': 0})
        self.assertEqual(report['checks']['widget_private_abi']['exit_code'], 77)
        self.assertEqual(report['checks']['intent_resources']['counts'],
                         {'total': 1, 'passed': 1, 'skipped': 0, 'failures': 0})
        self.assert_manual_not_run(report)
        manifest_path = report_path.with_name('build-manifest.json')
        manifest = json.loads(manifest_path.read_text())
        commit = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'],
                                         text=True).strip()
        self.assertEqual(manifest['status'], 'complete')
        self.assertEqual(manifest['kind'], 'unsigned-check')
        self.assertEqual(manifest['source_before']['commit'], commit)
        self.assertFalse(manifest['source_before']['dirty'])
        self.assertEqual(manifest['source_before'], manifest['source_after'])
        self.assertEqual(manifest['source_integrity'], 'observed-unchanged')
        self.assertEqual(manifest['product_version'],
                         {'status': 'recorded', 'version': '1.2.3', 'build': '130'})
        self.assertEqual(manifest['toolchain']['xcode']['version'], '26.6')
        self.assertEqual(manifest['toolchain']['swift']['version'], '6.3.3')
        artifact = manifest['artifacts'][0]
        self.assertEqual(artifact['name'], 'app')
        binary = next(item for item in artifact['entries'] if item['path'] == 'Contents/fixture-binary')
        self.assertEqual(binary['sha256'], hashlib.sha256(b'fixture-app\n').hexdigest())
        for path in (report_path, manifest_path, report_path.with_name('check-summary.md')):
            self.assertNotIn(str(self.base), path.read_text())
        summary = report_path.with_name('check-summary.md').read_text()
        self.assertIn('| widget_private_abi | skipped |', summary)
        self.assertIn('| live_clients | not-run |', summary)

    def test_parallel_checkouts_own_only_their_runs_on_success_and_build_failure(self):
        for override in (False, True):
            with self.subTest(shared_override=override):
                suffix = 'override' if override else 'default'
                repos = [self.fixture('success-' + suffix), self.fixture('failure-' + suffix)]
                parent = self.base / 'shared-derived-parent' if override else self.runtime / 'Lunavect-Check.noindex'
                parent.mkdir(exist_ok=True)
                sentinel = parent / ('sibling-' + suffix) / 'keep.txt'
                sentinel.parent.mkdir()
                sentinel.write_text('Another task owns this product\n')
                barrier = self.base / ('barrier-' + suffix)
                barrier.mkdir()
                common = {'CHECK_FIXTURE_BARRIER': str(barrier)}
                if override:
                    common['WEEKLEFT_CHECK_DERIVED_DATA'] = str(parent)
                with ThreadPoolExecutor(max_workers=2) as executor:
                    first = executor.submit(self.run_check, repos[0], **common)
                    second = executor.submit(self.run_check, repos[1], **common,
                                             CHECK_FIXTURE_FAIL='unsigned_build')
                    results = [first.result(), second.result()]
                self.assertEqual(results[0][0].returncode, 0, results[0][0].stdout + results[0][0].stderr)
                self.assertEqual(results[1][0].returncode, 42, results[1][0].stdout + results[1][0].stderr)
                derived = []
                for process, report, report_path, trace in results:
                    events = self.read_trace(trace)
                    self.assertTrue(all(event['opt_in'] == (['LUNAVECT_INTENT_BUNDLE_PATHS'] if '--filter' in event['args'] else []) for event in events))
                    build = next(event for event in events
                                 if event['tool'] == 'xcodebuild' and '-derivedDataPath' in event['args'])
                    path = Path(build['args'][build['args'].index('-derivedDataPath') + 1])
                    derived.append(path)
                    self.assertEqual(path.parent.parent, parent)
                    self.assertFalse(path.parent.exists(), 'Owned run directory survived cleanup')
                    self.assert_manual_not_run(report)
                self.assertNotEqual(derived[0], derived[1])
                self.assertEqual(sentinel.read_text(), 'Another task owns this product\n')
                self.assertFalse(self.forbidden.exists(), 'Check tried to change shared app registration')
                self.assert_success_evidence(repos[0], results[0][1], results[0][2])
                failed = results[1][1]
                self.assertEqual(failed['status'], 'failed')
                self.assertEqual(failed['checks']['unsigned_build']['exit_code'], 42)
                for stage in ('hook_helper', 'product_resources', 'intent_resources', 'build_provenance'):
                    self.assertEqual(failed['checks'][stage]['status'], 'not-run')
                pending = json.loads(results[1][2].with_name('build-manifest.json').read_text())
                self.assertEqual(pending['status'], 'started')
                self.assertNotIn('artifacts', pending)

    def test_swift_assertion_failure_keeps_later_checks_not_run_and_cleans_early_run(self):
        repo = self.fixture('swift-failure')
        process, report, report_path, trace = self.run_check(repo, CHECK_FIXTURE_FAIL='swift_tests')
        self.assertEqual(process.returncode, 1, process.stdout + process.stderr)
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['checks']['swift_tests']['counts'],
                         {'total': 2, 'passed': 1, 'skipped': 0, 'failures': 5})
        for stage in STAGES[STAGES.index('swift_tests') + 1:]:
            self.assertEqual(report['checks'][stage]['status'], 'not-run', stage)
        self.assert_manual_not_run(report)
        self.assertFalse(list((self.runtime / 'Lunavect-Check.noindex').glob('run.*')))
        self.assertFalse(any(event['tool'] == 'clang' for event in self.read_trace(trace)))
        self.assertFalse(self.forbidden.exists())

    def test_intent_resource_failure_blocks_provenance_and_cleans_products(self):
        repo = self.fixture('intent-failure')
        process, report, report_path, trace = self.run_check(repo, CHECK_FIXTURE_FAIL='intent_resources')
        self.assertEqual(process.returncode, 1, process.stdout + process.stderr)
        self.assertEqual(report['checks']['intent_resources']['status'], 'failed')
        self.assertEqual(report['checks']['build_provenance']['status'], 'not-run')
        self.assertFalse(list((self.runtime / 'Lunavect-Check.noindex').glob('run.*')))

    def test_intent_resource_gate_rejects_empty_or_skipped_filtered_runs(self):
        for output in ('Executed 0 tests, with 0 failures in 0.001 seconds',
                       'Executed 1 test, with 1 test skipped and 0 failures in 0.001 seconds'):
            report = self.base / 'empty-intents.json'
            self.assertEqual(self.run_reporter('init', report).returncode, 0)
            result = self.run_reporter('run', report, 'intent_resources', sys.executable, '-c', 'print(' + repr(output) + ')')
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(report.read_text())['checks']['intent_resources']['status'], 'failed')

    def test_unavailable_results_parent_does_not_leak_an_allocated_run(self):
        repo = self.fixture('results-parent-failure')
        blocked = self.base / 'results-is-a-file'
        blocked.write_text('Do not replace this existing file\n')
        parent = self.runtime / 'Lunavect-Check.noindex'
        parent.mkdir()
        sibling = parent / 'other-task-product'
        sibling.mkdir()
        (sibling / 'keep.txt').write_text('owned by another task\n')
        result = subprocess.run(['/bin/bash', str(repo / 'scripts/check.sh')],
                                cwd=self.base, env={**self.env, 'WEEKLEFT_CHECK_RESULTS': str(blocked)},
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(blocked.read_text(), 'Do not replace this existing file\n')
        self.assertEqual(list(parent.iterdir()), [sibling], result.stdout + result.stderr)
        self.assertEqual((sibling / 'keep.txt').read_text(), 'owned by another task\n')

    def run_reporter(self, *arguments):
        return subprocess.run([sys.executable, '-B', str(REPORTER), *map(str, arguments)],
                              capture_output=True, text=True, timeout=10)

    def test_failure_summary_without_case_lines_does_not_invent_passed_test_count(self):
        report = self.base / 'failure-report.json'
        self.assertEqual(self.run_reporter('init', report).returncode, 0)
        program = "print('Executed 2 tests, with 5 failures (0 unexpected) in 0.1 seconds'); raise SystemExit(1)"
        result = self.run_reporter('run', report, 'swift_tests', sys.executable, '-c', program)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.run_reporter('finish', report, 1).returncode, 1)
        value = json.loads(report.read_text())
        self.assertIsNone(value['checks']['swift_tests']['counts']['passed'])
        self.assertEqual(value['checks']['swift_tests']['counts']['failures'], 5)
        self.assertEqual(value['checks']['unsigned_build']['status'], 'not-run')
        self.assertIn('unknown passed', report.with_name('check-summary.md').read_text())

    def test_python_subtest_failures_are_not_counted_as_failed_test_cases(self):
        report = self.base / 'python-subtests.json'
        self.assertEqual(self.run_reporter('init', report).returncode, 0)
        program = textwrap.dedent('''\
            import unittest
            class Fixture(unittest.TestCase):
                def test_passed(self):
                    self.assertTrue(True)
                def test_many_assertion_failures(self):
                    for value in range(5):
                        with self.subTest(value=value):
                            self.fail('Synthetic failing subtest')
                @unittest.skip('Optional fixture')
                def test_skipped(self):
                    self.fail('Must not run')
            unittest.main(verbosity=2)
        ''')
        result = self.run_reporter('run', report, 'python_tests', sys.executable, '-c', program)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.run_reporter('finish', report, 1).returncode, 1)
        value = json.loads(report.read_text())
        self.assertEqual(value['checks']['python_tests']['counts'],
                         {'total': 3, 'passed': None, 'skipped': 1, 'failures': 5})
        self.assertIn('unknown passed', report.with_name('check-summary.md').read_text())

    def test_zero_exit_cannot_certify_unstarted_required_stages(self):
        report = self.base / 'incomplete.json'
        self.assertEqual(self.run_reporter('init', report).returncode, 0)
        result = self.run_reporter('run', report, 'source_checkpoint', sys.executable,
                                   '-c', "print('Synthetic completed checkpoint')")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.run_reporter('finish', report, 0).returncode, 1)
        value = json.loads(report.read_text())
        self.assertEqual(value['status'], 'failed')
        self.assertEqual(value['exit_code'], 1)
        self.assertEqual(value['checks']['source_checkpoint']['status'], 'passed')
        for stage in STAGES[1:]:
            self.assertEqual(value['checks'][stage]['status'], 'not-run', stage)
        self.assert_manual_not_run(value)

    def test_exit_77_is_a_skip_only_for_the_optional_private_abi_stage(self):
        for stage, expected, exit_code in (('widget_private_abi', 'skipped', 0),
                                           ('widget_fallback', 'failed', 77)):
            with self.subTest(stage=stage):
                report = self.base / (stage + '.json')
                self.assertEqual(self.run_reporter('init', report).returncode, 0)
                result = self.run_reporter('run', report, stage, sys.executable, '-c', 'raise SystemExit(77)')
                self.assertEqual(result.returncode, exit_code)
                value = json.loads(report.read_text())
                self.assertEqual(value['checks'][stage]['status'], expected)
                self.assertEqual(value['checks'][stage]['exit_code'], 77)

    def test_unknown_stage_is_rejected_without_changing_existing_evidence(self):
        report = self.base / 'unknown-stage.json'
        self.assertEqual(self.run_reporter('init', report).returncode, 0)
        before = report.read_bytes()
        result = self.run_reporter('run', report, 'unrecognized_check', sys.executable, '-c', 'raise SystemExit(0)')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(report.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
