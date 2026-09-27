#!/usr/bin/env python3
"""Fetch the newest passed native render of one suite from an earlier CI run.

The scheduled native-render job compares against it with
`check-native-renders.py --baseline`. Candidates are successful `schedule` and
`workflow_dispatch` runs of the workflow on the given branch, newest first,
excluding the current run. An artifact counts only if its render-report.json
records a passed render of the same suite. The tool only reads the Actions API
through `gh` (a GITHUB_TOKEN with `actions: read` is enough); it never uploads,
approves or deletes anything.

Prints the baseline directory on stdout, or nothing when no baseline is
available, in which case the render runs without comparison. A failed lookup is
reported as a warning rather than failing the render job.
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


def passed_render(directory, suite):
    try:
        report = json.loads((directory / 'render-report.json').read_text())
    except (OSError, ValueError):
        return False
    return (report.get('render', {}).get('status') == 'passed'
            and report.get('environment', {}).get('suite') == suite
            and (directory / 'images').is_dir())


def find(args):
    for run in candidate_runs(args.gh, args.repository, args.workflow, args.branch, args.exclude_run)[:args.max_runs]:
        name = render_artifact(args.gh, args.repository, run, args.suite, args.arch)
        if name is None:
            continue
        with tempfile.TemporaryDirectory(prefix='render-baseline-', dir=args.output.parent) as temporary:
            staging = Path(temporary) / 'artifact'
            subprocess.run([args.gh, 'run', 'download', str(run['id']), '--repo', args.repository,
                            '--name', name, '--dir', str(staging)], check=True, timeout=300)
            if not passed_render(staging, args.suite):
                print(f'Skipping {name} from run {run["id"]}: no passed {args.suite} render report.', file=sys.stderr)
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
    parser.add_argument('--max-runs', type=int, default=10)
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
            note = f'No passed baseline for {args.suite} in earlier successful runs; comparison not-run.'
    print(note, file=sys.stderr)
    if args.summary:
        with args.summary.open('a') as summary:
            summary.write(f'- {note}\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
