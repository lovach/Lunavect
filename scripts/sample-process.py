#!/usr/bin/env python3
"""Read-only sampling of an explicitly identified macOS executable and PID."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
COUNTERS = ('cpu_user_ns', 'cpu_system_ns', 'disk_read_bytes', 'disk_write_bytes',
            'interrupt_wakeups', 'platform_idle_wakeups')


def summarize(samples):
    if len(samples) < 2:
        raise ValueError('At least two samples are required')
    if any(x.get('schema_version') != 2 or x.get('cpu_counter_unit') != 'nanoseconds'
           or x.get('mach_timebase_numer', 0) <= 0 or x.get('mach_timebase_denom', 0) <= 0
           for x in samples):
        raise ValueError('CPU units are unverified; legacy schema 1 mislabeled Mach ticks as nanoseconds')
    first, last = samples[0], samples[-1]
    if any((x['mach_timebase_numer'], x['mach_timebase_denom']) !=
           (first['mach_timebase_numer'], first['mach_timebase_denom']) for x in samples):
        raise ValueError('CPU timebase changed')
    if any((x['pid'], x['start_identity']) != (first['pid'], first['start_identity']) for x in samples):
        raise ValueError('Process identity changed; intervals must not be joined')
    for left, right in zip(samples, samples[1:]):
        if right['monotonic_seconds'] <= left['monotonic_seconds'] or any(right[key] < left[key] for key in COUNTERS):
            raise ValueError('Nonmonotonic process counters; interval is invalid')
    elapsed = last['monotonic_seconds'] - first['monotonic_seconds']
    delta = {key: last[key] - first[key] for key in COUNTERS}
    cpu = (delta['cpu_user_ns'] + delta['cpu_system_ns']) / 1e9
    return {'wall_seconds': elapsed, 'cpu_seconds': cpu, 'cpu_percent_one_core': 100 * cpu / elapsed,
            'rss_max_sampled_bytes': max(x['rss_bytes'] for x in samples),
            'rss_median_sampled_bytes': statistics.median(x['rss_bytes'] for x in samples),
            'footprint_max_sampled_bytes': max(x['physical_footprint_bytes'] for x in samples),
            'counter_deltas': delta}


def snapshot(helper, executable, pid):
    result = subprocess.run([str(helper), str(executable), str(pid)], capture_output=True, text=True, timeout=5)
    reasons = {3: 'Process exited or identity could not be verified', 4: 'PID does not match exact executable',
               5: 'Process resource counters are unavailable',
               6: 'CPU timebase is unavailable or nanosecond conversion overflowed'}
    if result.returncode:
        raise ValueError(reasons.get(result.returncode, 'Invalid process sampler request'))
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', required=True, type=Path, help='Exact executable path, never a name/command-line match')
    parser.add_argument('--pid', required=True, type=int, help='Explicit process ID; identity is rechecked for every sample')
    parser.add_argument('--scenario', required=True, choices=('idle', 'active', 'wake', 'large-archive', 'synthetic-fixture'))
    parser.add_argument('--duration', type=float, default=30)
    parser.add_argument('--interval', type=float, default=1)
    parser.add_argument('--output', required=True, type=Path, help='New JSON file')
    args = parser.parse_args()
    if not (0.05 <= args.interval <= 60 and args.interval <= args.duration <= 3600 and args.pid > 0):
        parser.error('Require interval 0.05..60, duration interval..3600, and positive PID')
    executable = args.executable.resolve(strict=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive file creation prevents clobbering someone else's measurements.
    with args.output.open('x') as output:
        report = {'schema_version': 2, 'status': 'not-run', 'scenario': args.scenario,
                  'cpu_counter_unit': 'nanoseconds',
                  'cpu_conversion': 'libproc Mach absolute ticks * mach_timebase_numer / mach_timebase_denom; checked uint128 intermediate',
                  'executable': {'name': executable.name, 'sha256': hashlib.sha256(executable.read_bytes()).hexdigest()},
                  'environment': {'macos': platform.mac_ver()[0], 'architecture': platform.machine()},
                  'requested_duration_seconds': args.duration, 'interval_seconds': args.interval, 'samples': [],
                  'scope': 'Explicit PID only; no child-process aggregation, task sampling, arguments, memory, accounts or installation changes',
                  'limitations': ['Sampled RSS can miss short peaks.', 'CPU percent uses one core as 100%.',
                                  'Disk bytes are OS process counters, not logical file sizes or battery consumption.',
                                  'No workload is triggered; the operator supplies the named scenario.']}
        try:
            if platform.system() != 'Darwin':
                raise ValueError('macOS libproc sampler is unavailable')
            with tempfile.TemporaryDirectory(prefix='lunavect-sampler-') as temporary:
                helper = Path(temporary) / 'metrics'
                subprocess.run(['xcrun', 'clang', '-O2', '-Wall', '-Wextra', '-Werror',
                                str(ROOT / 'scripts/performance/process-metrics.c'), '-o', str(helper)],
                               check=True, capture_output=True, timeout=60)
                report['samples'].append(snapshot(helper, executable, args.pid))
                start = time.monotonic()
                while True:
                    remaining = args.duration - (time.monotonic() - start)
                    if remaining > 0:
                        time.sleep(min(args.interval, remaining))
                    report['samples'].append(snapshot(helper, executable, args.pid))
                    if time.monotonic() - start >= args.duration:
                        break
                report['summary'] = summarize(report['samples'])
                report['status'] = 'passed'
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            report.update(status='failed', reason=str(error) if isinstance(error, ValueError) else type(error).__name__)
        json.dump(report, output, indent=2)
        output.write('\n')
    print('Process measurement: ' + report['status'])
    return int(report['status'] != 'passed')


if __name__ == '__main__':
    raise SystemExit(main())
