# GitHub download and repository statistics

Lunavect sends no session data or app usage statistics to its developer. There is no app telemetry, analytics identifier or website analytics integration. The only statistics used by the project are the counters GitHub already provides for release downloads and repository traffic.

## Available information

| GitHub report | What it tells us | Limits |
| --- | --- | --- |
| Release assets | Cumulative requests per published file, grouped by release and file type | Downloads are not unique people or installations. ZIP counts include updates; appcast requests are update-feed checks, not installer downloads. |
| Repository views and clones | Totals and GitHub's unique counts for the returned period | GitHub documents a 14-day window. Inspect the actual returned dates; missing or stale reports are not zero traffic. |
| Referring sites and popular pages | The leading sources and repository paths reported by GitHub | This is repository traffic, not a full website analytics report or attribution for individual downloads. |

These reports do not reveal sessions, projects, app launches, active users, feature usage or retention. They cannot connect a repository visitor to an app installation. Do not sum unique counts from overlapping windows or present file download totals as the number of users.

GitHub documents the [release asset download counter](https://docs.github.com/en/rest/releases/assets) and [repository traffic reports](https://docs.github.com/en/rest/metrics/traffic). GitHub's own handling of web requests is separate from Lunavect; see [Privacy and permissions](privacy.md).

## Save a local snapshot

The maintainer script reads GitHub using an already authenticated `gh` CLI with repository traffic access. It is not bundled with the app, does not contact user installations, does not schedule itself and does not upload its reports.

Run it from the repository root, with a new output directory outside the public checkout:

```sh
python3 scripts/collect-github-metrics.py \
  --repo lovach/Lunavect \
  --output /absolute/path/to/new-github-snapshot
```

It saves the returned release, traffic, referrer and path responses, plus `summary.json`. The summary distinguishes DMG, ZIP, appcast and other assets and records both collection time and returned traffic dates. An unavailable endpoint is reported as unavailable, not as zero.

To compare asset counters with an earlier snapshot:

```sh
python3 scripts/collect-github-metrics.py \
  --repo lovach/Lunavect \
  --output /absolute/path/to/next-github-snapshot \
  --previous /absolute/path/to/previous-github-snapshot/summary.json
```

The comparison uses stable asset IDs. New or replaced assets and decreasing counters have no comparable delta. Keep snapshots private and record their observation dates when reporting results.
