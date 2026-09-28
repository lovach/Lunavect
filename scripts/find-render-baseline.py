#!/usr/bin/env python3
"""Fetch the newest reviewed native render of one suite from an earlier CI run.

The scheduled native-render job compares against it with
`check-native-renders.py --baseline`. Candidates are successful `schedule` and
`workflow_dispatch` runs of the workflow on the given branch, newest first,
excluding the current run. An artifact counts only if its render-report.json
records a passed render of the same suite that is itself reviewed: its own
comparison with the previous baseline passed, or it was recorded as a new
reference by an explicit manual dispatch (`--record-baseline`). A green run
without a comparison (a lookup failure, an expired or skipped baseline, the
first run) is never promoted. Runs without a render artifact of the suite do
not count toward `--max-runs`. The tool only reads the Actions API through `gh`
(a GITHUB_TOKEN with `actions: read` is enough); it never uploads, approves or
deletes anything.

Prints the baseline directory on stdout, or nothing when no reviewed baseline
is available or the lookup failed; the workflow then renders for the gallery
and fails the job, so a reference is only ever recorded on purpose.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

EVENTS = ('schedule', 'workflow_dispatch')


def gh_json(gh, endpoint):
    output = subprocess.run([gh, 'api', endpoint], check=True, capture_output=True, text=True, timeout=120).stdout
    return json.loads(output)


def candidate_runs(gh, repository, workflow, branch, exclude):
    runs = []
    for event in EVENTS:
        listing = gh_json(gh, f'repos/{repository}/actions/workflows/{workflow}/runs'
                              f'?branch={branch}&event={event}&status=success&per_page=20')
        runs.extend(run for run in listing.get('workflow_runs', []) if str(run['id']) != str(exclude))
    return sorted(runs, key=lambda run: run['created_at'], reverse=True)


def render_artifact(gh, repository, run, suite, arch):
    """The last attempt's unexpired render artifact of this suite and architecture."""
    pattern = re.compile(rf'synthetic-native-render-{re.escape(suite)}-[0-9a-f]{{40}}-{re.escape(arch)}-(\d+)')
    listing = gh_json(gh, f'repos/{repository}/actions/runs/{run["id"]}/artifacts?per_page=100')
    matches = [(int(match[1]), artifact['name']) for artifact in listing.get('artifacts', [])
               if not artifact.get('expired') and (match := pattern.fullmatch(artifact['name']))]
    return max(matches)[1] if matches else None


def reviewed_render(directory, suite):
    """None for a usable baseline, otherwise why the render cannot be one."""
    try:
        report = json.loads((directory / 'render-report.json').read_text())
    except (OSError, ValueError):
        return 'no readable render report'
    if (report.get('render', {}).get('status') != 'passed' or report.get('environment', {}).get('suite') != suite
            or not (directory / 'images').is_dir()):
        return f'no passed {suite} render report'
    if (report.get('comparison', {}).get('status') != 'passed'
            and report.get('baseline_record', {}).get('status') != 'recorded'):
        return 'not compared with a reviewed baseline and not recorded as a reference by a manual dispatch'
    return None


def find(args):
    inspected = 0
    for run in candidate_runs(args.gh, args.repository, args.workflow, args.branch, args.exclude_run):
        if inspected >= args.max_runs:
            break
        name = render_artifact(args.gh, args.repository, run, args.suite, args.arch)
        if name is None:
            # A dispatch of another job has no render: it does not use up the search.
            continue
        inspected += 1
        with tempfile.TemporaryDirectory(prefix='render-baseline-', dir=args.output.parent) as temporary:
            staging = Path(temporary) / 'artifact'
            subprocess.run([args.gh, 'run', 'download', str(run['id']), '--repo', args.repository,
                            '--name', name, '--dir', str(staging)], check=True, timeout=300)
            reason = reviewed_render(staging, args.suite)
            if reason:
                print(f'Skipping {name} from run {run["id"]}: {reason}.', file=sys.stderr)
                continue
            staging.rename(args.output)
        return run, name
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--repository', required=True, help='owner/name')
    parser.add_argument('--workflow', required=True, help='Workflow file name, e.g. ci.yml')
    parser.add_argument('--branch', required=True)
    parser.add_argument('--suite', required=True)
    parser.add_argument('--arch', required=True, help='runner.arch recorded in the artifact name')
    parser.add_argument('--exclude-run', required=True, help='The current run, which is never its own baseline')
    parser.add_argument('--output', type=Path, required=True, help='New directory for the downloaded baseline')
    parser.add_argument('--summary', type=Path, help='Markdown file to append one provenance line to')
    parser.add_argument('--gh', default='gh', help='GitHub CLI executable')
    parser.add_argument('--max-runs', type=int, default=10, help='Runs with a render artifact of the suite to inspect')
    args = parser.parse_args()
    args.output = args.output.resolve()
    if args.output.exists() or args.output.is_symlink():
        parser.error('--output must be a new directory')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        found = find(args)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        note = f'Native render baseline lookup failed ({type(error).__name__}); comparison not-run for {args.suite}.'
        print(f'::warning::{note}', file=sys.stderr)
        found = None
    else:
        if found:
            run, name = found
            note = (f'Native render baseline for {args.suite}: `{name}` from run {run["id"]} '
                    f'({run["event"]}, {run["created_at"]}).')
            print(args.output)
        else:
            note = (f'No reviewed baseline for {args.suite} in earlier successful runs; comparison not-run. '
                    'Review the gallery, then record one with a manual dispatch that clears render_baseline.')
    print(note, file=sys.stderr)
    if args.summary:
        with args.summary.open('a') as summary:
            summary.write(f'- {note}\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
