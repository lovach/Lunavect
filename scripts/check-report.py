#!/usr/bin/env python3
"""Run local check stages and preserve explicit evidence, including after failure."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


STAGES = (
    'source_checkpoint', 'python_tests', 'swift_tests', 'widget_probe_build',
    'widget_fallback', 'widget_private_abi', 'unsigned_build', 'hook_helper',
    'product_resources', 'intent_resources', 'build_provenance',
)
MANUAL = {
    'native_render': 'Separate opt-in scripts/check-native-renders.py command.',
    'live_clients': 'No account/client integration enabled by this command.',
    'desktop_widget': 'Requires actual desktop placement and refresh checks.',
    'signed_distribution': 'No signing, notarization, install or update performed.',
    'supported_macos_hardware': 'One host does not prove the supported OS/hardware matrix.',
}


def save(path, report):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(report, indent=2) + '\n')
    temporary.replace(path)


def test_counts(stage, output):
    if stage in ('swift_tests', 'intent_resources'):
        matches = re.findall(
            r'Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?', output)
        if matches:
            total, skipped, failures = (int(x or 0) for x in matches[-1])
            # XCTest's failure count is assertions, not failed test cases.
            # Never subtract it to invent a passed-case count.
            cases = re.findall(r"^Test Case .+ (passed|failed|skipped) \(", output, re.M)
            passed = total - skipped if failures == 0 else cases.count('passed') if len(cases) == total else None
            return dict(total=total, passed=passed,
                        skipped=skipped, failures=failures)
    if stage == 'python_tests':
        total = re.search(r'Ran (\d+) tests? in ', output)
        result = re.search(r'^(OK|FAILED)(?: \(([^\n]*)\))?$', output, re.M)
        if total and result:
            numbers = dict(re.findall(r'(failures|errors|skipped)=(\d+)', result[2] or ''))
            skipped = int(numbers.get('skipped', 0))
            failures = int(numbers.get('failures', 0)) + int(numbers.get('errors', 0))
            # A single unittest case can contain multiple failing subtests.
            return dict(total=int(total[1]), passed=int(total[1]) - skipped if failures == 0 else None,
                        skipped=skipped, failures=failures)
    return None


def check_environment():
    # A reused developer shell must not turn a default check into a live test,
    # image exporter, session navigation action or private-history read.
    return {key: value for key, value in os.environ.items() if not key.startswith('LUNAVECT_')}


def run_stage(path, stage, command):
    report = json.loads(path.read_text())
    record = report['checks'][stage]
    record['status'] = 'running'
    save(path, report)
    print(f'CHECK: {stage}', flush=True)
    output = []
    try:
        # Logs stay local. CI uploads only the structured JSON/Markdown, whose
        # schema never embeds output, environment values or personal paths.
        with path.with_name(stage + '.log').open('w') as log:
            process = subprocess.Popen(command, env=check_environment(), stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True, errors='replace')
            for line in process.stdout:
                sys.stdout.write(line)
                log.write(line)
                output.append(line)
            status = process.wait()
    except OSError:
        status = 127
    skipped = stage == 'widget_private_abi' and status == 77
    record.update(status='skipped' if skipped else 'passed' if status == 0 else 'failed',
                  exit_code=status)
    if skipped:
        record['reason'] = 'Unsupported private descriptor ABI; standard background fallback remains available.'
    if stage in ('swift_tests', 'python_tests', 'intent_resources'):
        record['counts'] = test_counts(stage, ''.join(output))
        if record['counts'] is None:
            record['reason'] = 'Test count could not be parsed; see local stage log.'
        if stage == 'intent_resources' and record['counts'] != dict(total=1, passed=1, skipped=0, failures=0):
            status = status or 1
            record.update(status='failed', exit_code=status,
                          reason='The built app/widget metadata test must run once and pass without skips.')
    save(path, report)
    print(f'{record["status"].upper()}: {stage}', flush=True)
    return 0 if skipped else status if status >= 0 else 128 - status


def finish(path, exit_code):
    if not path.exists():
        return
    report = json.loads(path.read_text())
    for record in report['checks'].values():
        if record['status'] == 'running':
            record.update(status='failed', reason='Check interrupted before completion.')
    complete = all(report['checks'][stage]['status'] == 'passed' or
                   (stage == 'widget_private_abi' and report['checks'][stage]['status'] == 'skipped')
                   for stage in STAGES)
    if exit_code == 0 and not complete:
        exit_code = 1
    report['status'] = 'passed' if exit_code == 0 else 'failed'
    report['exit_code'] = exit_code
    save(path, report)
    lines = ['# Local unsigned checks', '', f'Overall: **{report["status"]}**', '',
             '| Check | Status | Test counts / scope |', '| --- | --- | --- |']
    for stage, record in report['checks'].items():
        counts = record.get('counts')
        passed = counts['passed'] if counts and counts['passed'] is not None else 'unknown'
        detail = (f'{passed} passed; {counts["skipped"]} skipped; '
                  f'{counts["failures"]} failures; {counts["total"]} total') if counts else record.get('reason', '')
        lines.append(f'| {stage} | {record["status"]} | {detail} |')
    path.with_name('check-summary.md').write_text('\n'.join(lines) + '\n')
    print('\n'.join(lines))
    return exit_code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('init', 'run', 'finish'))
    parser.add_argument('report', type=Path)
    parser.add_argument('arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.action == 'init':
        save(args.report, dict(schema_version=1, status='running',
             checks={**{name: dict(status='not-run') for name in STAGES},
                     **{name: dict(status='not-run', reason=reason) for name, reason in MANUAL.items()}}))
    elif args.action == 'finish':
        return finish(args.report, int(args.arguments[0]))
    else:
        if len(args.arguments) < 2 or args.arguments[0] not in STAGES:
            parser.error('run requires a known stage and a command')
        return run_stage(args.report, args.arguments[0], args.arguments[1:])
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
