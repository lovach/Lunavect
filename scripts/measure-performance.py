#!/usr/bin/env python3
"""Measure synthetic production-code workloads; build time is outside phase timers."""
import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PHASES = ('fixture-generation', 'archive-import', 'history-merge-summary-roundtrip', 'session-arrangement')


def aggregate(samples):
    if not samples or any(sample['scenario'] != samples[0]['scenario'] for sample in samples):
        raise ValueError('Samples must describe the same nonempty workload')
    result = {}
    for name in PHASES:
        values = [next(phase for phase in sample['phases'] if phase['name'] == name) for sample in samples]
        walls = [value['wall_seconds'] for value in values]
        if any(not math.isfinite(wall) or wall <= 0 for wall in walls):
            raise ValueError('Invalid wall-time measurement')
        result[name] = {'wall_median_seconds': statistics.median(walls), 'wall_min_seconds': min(walls),
                        'wall_max_seconds': max(walls), 'samples': len(values)}
        if all(value['resource_counters_status'] == 'passed' for value in values):
            result[name]['cpu_median_seconds'] = statistics.median(value['cpu_user_seconds'] + value['cpu_system_seconds'] for value in values)
            result[name]['rss_max_process_high_water_bytes'] = max(value['rss_peak_process_bytes'] for value in values)
        else:
            result[name]['resource_counters_status'] = 'unavailable'
    return result


def run(command, log, env=None):
    with log.open('w') as stream:
        return subprocess.run(command, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=1200).returncode


def markdown_summary(report, provenance):
    lines = ['# Synthetic performance measurement', '',
             f"Measurement/run: **{report['status']}**. Source provenance: **{provenance}**.", '',
             'Synthetic production-code workload; no installed-app or battery conclusion.', '']
    if report.get('summary'):
        lines += ['| Phase | Wall median (s) | Wall min–max (s) | CPU median (s) | Process high-water RSS max (MiB) |',
                  '| --- | ---: | ---: | ---: | ---: |']
        for name, value in report['summary'].items():
            cpu = f"{value['cpu_median_seconds']:.6f}" if 'cpu_median_seconds' in value else 'unavailable'
            rss = f"{value['rss_max_process_high_water_bytes'] / 1048576:.2f}" if 'rss_max_process_high_water_bytes' in value else 'unavailable'
            lines.append(f"| {name} | {value['wall_median_seconds']:.6f} | {value['wall_min_seconds']:.6f}–{value['wall_max_seconds']:.6f} | {cpu} | {rss} |")
        lines += ['', 'RSS is cumulative for the XCTest process, including earlier phases, not a phase allocation delta.',
                  'OS I/O block counters and exact workload dimensions are in performance-report.json.',
                  'Build/startup are outside phase timers. Host load and caches are not controlled.']
    if report.get('reason'):
        lines += ['', 'Failure reason is recorded in performance-report.json; raw diagnostics remain local.']
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true')
    parser.add_argument('--profile', choices=('quick', 'large'), default='large')
    parser.add_argument('--configuration', choices=('debug', 'release'), default='release')
    parser.add_argument('--samples', type=int, default=3)
    parser.add_argument('--output', required=True, type=Path, help='New directory for reports; logs remain local')
    args = parser.parse_args()
    if not 1 <= args.samples <= 10:
        parser.error('--samples must be 1..10')
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        output.mkdir()
    except FileExistsError:
        parser.error('--output must be a new directory')
    report = {'schema_version': 1, 'status': 'not-run', 'profile': args.profile, 'configuration': args.configuration,
              'environment': {'macos': platform.mac_ver()[0], 'architecture': platform.machine()},
              'samples': [], 'limitations': ['Synthetic workload only; no battery, installed-app, live-client or cross-machine claim.',
                                           'Background host load and filesystem caches are not controlled.']}
    lock = None
    try:
        if args.run:
            scratch = ROOT / '.build/performance-check'
            scratch.mkdir(parents=True, exist_ok=True)
            lock = (scratch / 'measurement.lock').open('w')
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            manifest = output / 'build-manifest.json'
            if run([sys.executable, 'scripts/build-manifest.py', 'begin', '--source-root', str(ROOT), '--output', str(manifest),
                    '--kind', 'synthetic-performance'], output / 'provenance.log'):
                raise ValueError('Source checkpoint failed')
            build = ['xcrun', 'swift', 'build', '--build-tests', '--jobs', '2', '--configuration', args.configuration,
                     '-Xswiftc', '-enable-testing', '--scratch-path', str(scratch)]
            if run(build, output / 'build.log'):
                raise ValueError('Test products did not build; see local build.log')
            for index in range(args.samples):
                result = output / f'sample-{index + 1}.json'
                env = {key: value for key, value in os.environ.items() if not key.startswith('LUNAVECT_')}
                env.update(LUNAVECT_BENCHMARK_OUTPUT=str(result), LUNAVECT_BENCHMARK_PROFILE=args.profile)
                command = ['xcrun', 'swift', 'test', '--skip-build', '--jobs', '2', '--configuration', args.configuration,
                           '--scratch-path', str(scratch), '--filter', 'SyntheticPerformanceTests.testRunSyntheticWorkload']
                if run(command, output / f'sample-{index + 1}.log', env=env):
                    raise ValueError('Synthetic workload failed; see local sample log')
                report['samples'].append(json.loads(result.read_text()))
            report['summary'] = aggregate(report['samples'])
            report['scenario'] = report['samples'][0]['scenario']
            report['status'] = 'passed'
    except (OSError, ValueError, KeyError, StopIteration, subprocess.SubprocessError) as error:
        report.update(status='failed', reason=str(error) if isinstance(error, ValueError) else type(error).__name__)
    finally:
        result_path = output / 'performance-report.json'
        result_path.write_text(json.dumps(report, indent=2) + '\n')
        manifest = output / 'build-manifest.json'
        provenance = 'not-run'
        if manifest.is_file():
            try:
                status = run([sys.executable, 'scripts/build-manifest.py', 'finalize', '--source-root', str(ROOT),
                              '--manifest', str(manifest), '--artifact', f'measurement={result_path}'], output / 'provenance-finalize.log')
            except (OSError, subprocess.SubprocessError):
                status = 1
            provenance = 'passed' if status == 0 else 'failed'
            # Do not mutate the artifact after hashing it; provenance has its own result.
            if status:
                report['status'] = 'failed'
                print('Provenance failed; measurement report is not evidence of a fixed source.', file=sys.stderr)
        (output / 'run-summary.json').write_text(json.dumps({'status': report['status'], 'provenance': provenance,
            'measurement_report': 'performance-report.json', 'build_manifest': 'build-manifest.json' if manifest.is_file() else None}, indent=2) + '\n')
        (output / 'summary.md').write_text(markdown_summary(report, provenance))
        if lock is not None:
            lock.close()
    print('Synthetic measurement: ' + report['status'])
    return int(report['status'] == 'failed')


if __name__ == '__main__':
    raise SystemExit(main())
