import importlib.util
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


sampler = module('process_sampler', 'scripts/sample-process.py')
benchmark = module('performance_measurement', 'scripts/measure-performance.py')


class PerformanceToolTests(unittest.TestCase):
    def snapshot(self, time=1, start=123, cpu=100):
        return dict(schema_version=2, cpu_counter_unit='nanoseconds', mach_timebase_numer=125,
                    mach_timebase_denom=3, pid=17, start_identity=start, monotonic_seconds=time, cpu_user_ns=cpu, cpu_system_ns=0,
                    rss_bytes=1000, physical_footprint_bytes=800, disk_read_bytes=200, disk_write_bytes=300,
                    interrupt_wakeups=1, platform_idle_wakeups=2)

    def test_sampler_counter_deltas_and_sampled_rss(self):
        before, after = self.snapshot(), self.snapshot(time=3, cpu=1_000_000_100)
        after['rss_bytes'] = 2000
        result = sampler.summarize([before, after])
        self.assertEqual(result['wall_seconds'], 2)
        self.assertEqual(result['cpu_percent_one_core'], 50)
        self.assertEqual(result['rss_max_sampled_bytes'], 2000)
        self.assertEqual(result['counter_deltas']['disk_write_bytes'], 0)

    def test_sampler_rejects_pid_reuse_and_counter_reset(self):
        for after in [self.snapshot(time=2, start=456), self.snapshot(time=2, cpu=50), self.snapshot(time=1)]:
            with self.assertRaises(ValueError):
                sampler.summarize([self.snapshot(), after])

    def test_sampler_rejects_legacy_units_and_changed_timebase(self):
        for key, value in [('schema_version', 1), ('cpu_counter_unit', 'ticks'),
                           ('mach_timebase_numer', 0), ('mach_timebase_denom', 1)]:
            after = self.snapshot(time=2)
            after[key] = value
            with self.assertRaises(ValueError):
                sampler.summarize([self.snapshot(), after])

    @unittest.skipUnless(platform.system() == 'Darwin', 'Mach time is a macOS API')
    def test_native_conversion_boundaries_and_getrusage_calibration(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper, fixture = root / 'metrics', root / 'cpu-fixture'
            for source, output in [(ROOT / 'scripts/performance/process-metrics.c', helper),
                                   (ROOT / 'Tests/Scripts/process_cpu_fixture.c', fixture)]:
                subprocess.run(['xcrun', 'clang', '-O2', '-Wall', '-Wextra', '-Werror',
                                str(source), '-o', str(output)], check=True, capture_output=True)
            with subprocess.Popen([str(fixture)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  text=True) as process:
                try:
                    self.assertEqual(process.stdout.readline().strip(), 'ready')
                    before = sampler.snapshot(helper, fixture, process.pid)
                    process.stdin.write('\n'); process.stdin.flush()
                    reference = float(process.stdout.readline())
                    after = sampler.snapshot(helper, fixture, process.pid)
                    measured = sampler.summarize([before, after])['cpu_seconds']
                    self.assertGreater(reference, 0.24)
                    self.assertAlmostEqual(measured / reference, 1, delta=0.1)
                finally:
                    process.stdin.close()
                    process.wait(timeout=5)
                self.assertEqual(process.returncode, 0)

    def test_benchmark_medians_require_matching_scenarios_and_finite_time(self):
        def sample(wall, scenario=10):
            return {'scenario': {'records': scenario}, 'phases': [dict(name=name, wall_seconds=wall,
                    resource_counters_status='passed', cpu_user_seconds=wall / 2, cpu_system_seconds=0,
                    rss_peak_process_bytes=100) for name in benchmark.PHASES]}
        self.assertEqual(benchmark.aggregate([sample(4), sample(2), sample(9)])['archive-import']['wall_median_seconds'], 4)
        for samples in [[], [sample(1), sample(1, 20)], [sample(float('nan'))]]:
            with self.assertRaises(ValueError):
                benchmark.aggregate(samples)

    def test_benchmark_opt_in_and_existing_artifacts_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'new'
            command = [sys.executable, str(ROOT / 'scripts/measure-performance.py'), '--output', str(output)]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(json.loads((output / 'run-summary.json').read_text())['status'], 'not-run')
            before = (output / 'performance-report.json').read_bytes()
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual((output / 'performance-report.json').read_bytes(), before)

    def test_failed_provenance_cannot_become_success_or_change_hashed_measurement(self):
        sample = {'scenario': {'records': 1}, 'phases': [dict(name=name, wall_seconds=1,
                  resource_counters_status='unavailable') for name in benchmark.PHASES]}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / 'result'
            observed_artifact = []
            def fake_run(command, log, env=None):
                if 'begin' in command:
                    (output / 'build-manifest.json').write_text('{}')
                if '--skip-build' in command:
                    Path(env['LUNAVECT_BENCHMARK_OUTPUT']).write_text(json.dumps(sample))
                if 'finalize' in command:
                    observed_artifact.append((output / 'performance-report.json').read_bytes())
                    return 1
                return 0
            with patch.object(benchmark, 'ROOT', root), patch.object(benchmark, 'run', side_effect=fake_run), \
                 patch.object(sys, 'argv', ['measure', '--run', '--samples', '1', '--output', str(output)]):
                self.assertEqual(benchmark.main(), 1)
            self.assertEqual(observed_artifact, [(output / 'performance-report.json').read_bytes()])
            self.assertEqual(json.loads((output / 'run-summary.json').read_text())['status'], 'failed')
            self.assertIn('provenance: **failed**', (output / 'summary.md').read_text())
            self.assertIn('unavailable', (output / 'summary.md').read_text())

    @unittest.skipUnless(platform.system() == 'Darwin', 'libproc is a macOS API')
    def test_real_sampler_matches_only_its_explicit_fixture_executable(self):
        # Own fixture only. Never enumerate or select an installed app process.
        with tempfile.TemporaryDirectory() as temporary:
            helper = Path(temporary) / 'metrics'
            subprocess.run(['xcrun', 'clang', '-O2', '-Wall', '-Wextra', '-Werror',
                            str(ROOT / 'scripts/performance/process-metrics.c'), '-o', str(helper)], check=True, capture_output=True)
            process = subprocess.Popen(['/bin/sleep', '15'])
            self.addCleanup(lambda: process.poll() is None and process.terminate())
            try:
                first = sampler.snapshot(helper, Path('/bin/sleep'), process.pid)
                self.assertEqual(first['pid'], process.pid)
                self.assertGreater(first['rss_bytes'], 0)
                with self.assertRaisesRegex(ValueError, 'exact executable'):
                    sampler.snapshot(helper, Path('/bin/ls'), process.pid)
                output = Path(temporary) / 'sample.json'
                command = [sys.executable, str(ROOT / 'scripts/sample-process.py'), '--executable', '/bin/sleep',
                           '--pid', str(process.pid), '--scenario', 'synthetic-fixture', '--duration', '0.15',
                           '--interval', '0.05', '--output', str(output)]
                self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
                report = json.loads(output.read_text())
                self.assertEqual(report['status'], 'passed')
                self.assertGreaterEqual(len(report['samples']), 2)
                self.assertNotIn('/bin/sleep', output.read_text())
                process.terminate(); process.wait(timeout=5)
                with self.assertRaisesRegex(ValueError, 'exited'):
                    sampler.snapshot(helper, Path('/bin/sleep'), process.pid)
            finally:
                if process.poll() is None:
                    process.terminate(); process.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
