#!/usr/bin/env python3
"""Read public asset counters and GitHub's short-window traffic into local snapshots.

Requires an already authenticated gh for traffic access; never prints credentials.
This command does not schedule itself or upload the collected reports.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess


def asset_kind(name):
    lower = name.lower()
    if lower.endswith('.dmg'):
        return 'dmg'
    if lower.endswith('.zip'):
        return 'zip'
    if 'appcast' in lower:
        return 'appcast'
    return 'other'


def summarize(releases, views, clones, errors=None):
    assets = []
    totals = dict.fromkeys(('dmg', 'zip', 'appcast', 'other'), 0)
    for release in releases:
        if release.get('draft'):
            continue
        for asset in release.get('assets', []):
            kind = asset_kind(asset['name'])
            count = asset.get('download_count', 0)
            totals[kind] += count
            assets.append(dict(id=asset['id'], release=release['tag_name'], name=asset['name'],
                               kind=kind, downloads=count, created_at=asset.get('created_at'),
                               updated_at=asset.get('updated_at'), prerelease=release.get('prerelease', False)))
    def traffic(data, field):
        rows = data.get(field, []) if data else []
        dates = sorted(row['timestamp'] for row in rows)
        return None if data is None else dict(count=data.get('count'), uniques=data.get('uniques'),
                                               returned_start=dates[0] if dates else None,
                                               returned_end=dates[-1] if dates else None)
    return dict(asset_downloads=totals, assets=assets, views=traffic(views, 'views'),
                clones=traffic(clones, 'clones'), unavailable=errors or [],
                interpretation='File requests are not people or installations. ZIP includes updater downloads. '
                'Traffic describes returned dates, not necessarily today. Do not sum overlapping unique counts.')


def asset_deltas(current, previous):
    old = {row['id']: row for row in previous.get('assets', [])}
    result = []
    for row in current['assets']:
        before = old.get(row['id'])
        delta = row['downloads'] - before['downloads'] if before else None
        # New/replaced assets have no earlier observation. Counter decreases are not negative downloads.
        result.append(dict(id=row['id'], name=row['name'], delta=delta if delta is not None and delta >= 0 else None,
                           status='comparable' if delta is not None and delta >= 0 else 'new_or_reset'))
    return result


def fetch(endpoint, paginate=False):
    command = ['gh', 'api', '-H', 'Accept: application/vnd.github+json', '-H', 'Cache-Control: no-cache', endpoint]
    if paginate:
        command += ['--paginate', '--slurp']
    result = subprocess.run(command, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError('GitHub endpoint unavailable (gh exit %d)' % result.returncode)
    data = json.loads(result.stdout)
    return [row for page in data for row in page] if paginate else data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default='lovach/Lunavect')
    parser.add_argument('--output', type=Path, required=True, help='Local snapshot directory outside the public repository')
    parser.add_argument('--previous', type=Path, help='Earlier summary.json for stable asset-ID deltas')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo):
        parser.error('Invalid repository name')
    args.output.mkdir(parents=True, exist_ok=False)
    started = datetime.now(timezone.utc).isoformat()
    data, errors = {}, []
    endpoints = {'releases': f'repos/{args.repo}/releases?per_page=100',
                 'views': f'repos/{args.repo}/traffic/views?per=day',
                 'clones': f'repos/{args.repo}/traffic/clones?per=day',
                 'referrers': f'repos/{args.repo}/traffic/popular/referrers',
                 'paths': f'repos/{args.repo}/traffic/popular/paths'}
    for name, endpoint in endpoints.items():
        try:
            data[name] = fetch(endpoint, paginate=name == 'releases')
            (args.output / (name + '.json')).write_text(json.dumps(data[name], indent=2) + '\n')
        except (RuntimeError, OSError, subprocess.TimeoutExpired, ValueError) as error:
            errors.append(dict(endpoint=name, error=type(error).__name__))
            data[name] = None
    summary = summarize(data['releases'] or [], data['views'], data['clones'], errors)
    if data['releases'] is None:
        summary['asset_downloads'] = None  # Unknown must never become zero.
    summary.update(repo=args.repo, observed_at=started, completed_at=datetime.now(timezone.utc).isoformat())
    if args.previous:
        previous = json.loads(args.previous.read_text())
        if previous.get('repo') != args.repo:
            parser.error('Previous snapshot belongs to another repository')
        summary['previous_observed_at'] = previous.get('observed_at')
        summary['asset_deltas'] = asset_deltas(summary, previous)
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    return 1 if errors else 0


if __name__ == '__main__':
    raise SystemExit(main())
