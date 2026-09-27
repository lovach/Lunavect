# Optional technical statistics — maintainer setup

This is an **unconfigured release candidate**, not an enabled production service. Public releases through 0.2.3 contain no product analytics. Both public capture-token fields are blank. With no valid configuration, no analytics UI, identifiers or network requests are created. No third-party analytics SDK is included.

The scope is intentionally small: total launch events and navigation results in the app, download-link clicks on the website, and separate GitHub counters. There is no persistent installation/browser/user identifier. Do not add behavioral tracking, geographic enrichment, screen recording or user profiles through a project setting or future SDK default.

## Create the EU project

1. The owner creates a project in [PostHog EU](https://eu.posthog.com). Use EU hosting and a private project. Creating an account and accepting its terms remain owner actions; no account has been created by this change.
2. Disable IP capture in project settings. Keep session replay, autocapture, person profiles and unrelated products disabled. These clients already send `$geoip_disable: true` and `$process_person_profile: false`; they never call identify/alias or preload flags. Project configuration does not replace the payload restrictions.
3. Check the current [pricing and limits](https://posthog.com/pricing), choose a spending cap, and set the shortest appropriate event retention available for the account. Record the actual retention in [Privacy](privacy.md) before production activation. Do not promise a 30-day deletion period unless the project actually enforces it. No payment method or paid product is required by this code.
4. Copy the **public Project token**, starting with `phc_`. It is a capture token intended for client code. Never use a personal API key (`phx_`), OAuth credential or provider account token here. The public token enables event ingestion, not dashboard administration. Public event ingestion can be spoofed; these statistics are not a billing or security audit trail.
5. Configure the token in `Config/Analytics.xcconfig` for the release app and in `docs/assets/analytics/config.js` for the website. Host is fixed to `https://eu.i.posthog.com`; other hosts and plaintext HTTP are rejected. Release configuration includes this xcconfig; preview environments force analytics off. Debug builds can pass `LUNAVECT_ANALYTICS_TOKEN` and `LUNAVECT_ANALYTICS_HOST` as Xcode build settings when performing the explicit staging test.
6. Run local checks, then perform the real-project acceptance below before publishing the next signed app and the website together with the updated privacy page. Never replace the already published 0.2.3 files with an analytics build under the same version.

The owner only needs to provide the public capture token for configuration. Dashboard creation can be performed in the project UI; no personal API key needs to be shared or embedded.

## Event contract (schema 1)

All reported timestamps are rounded down to an hour. Every event has a random `uuid`, also used as the API-required `distinct_id`. A retry preserves both values and the timestamp. Different events always have different IDs, even on the same installation. No identifier is persisted in preferences or local storage; only the consent choice persists.

| Event | Meaning | Allowed properties beyond schema/surface/privacy flags |
| --- | --- | --- |
| `app_launched` | Launch observed while statistics are allowed; enabling statistics also records the current launch | `app_version`, `app_build`, `os_major` |
| `session_navigation_result` | An attempt through the session panel, menu, shortcut or notification completed or threw an error | App version/build, major macOS version, `provider`, `client`, `outcome` (`success`/`failed`) |
| `download_clicked` | A website link leading to an official release destination was clicked after consent | `source` (fixed category), `target` (`release_page`/`dmg`/`zip`) |

`success` means the navigation adapter returned without throwing; it is not an independent visual assertion that a person saw the intended tab. Client categories come from Lunavect's existing session metadata and may be unknown or stale. No exception text, title, session ID, project path, payload, token, quota or working interval can enter the typed event API.

The website accepts `utm_source=reddit`, `x`, `habr`, `producthunt`, `github`, `google`, `bing` or `newsletter`; otherwise it reduces recognized referrer domains to those categories, or `other`/`direct`. It sends no URL, referrer path, campaign or query string. Example campaign link:

`https://lovach.github.io/Lunavect/?utm_source=reddit`

Source belongs to the page on which the click occurred; attribution is not carried across pages, installations or devices. Ad blockers, stripped referrers and refusal create gaps. Current download buttons open GitHub's release page, so they emit `target=release_page`, not proof of a DMG transfer.

PostHog receives normal HTTPS connection information, including IP and request arrival time, despite the restricted payload and rounded event time. Disable project IP capture and disclose the processor. Do not describe the transport as sending literally no data. The privacy goal is no content or persistent user tracking, not a claim of universal legal compliance.

## Delivery and controls

- No choice or refusal: no analytics capture or network request. Missing/invalid configuration: also inactive.
- App: equal welcome choices plus an off-by-default toggle in Settings → General. Refusal does not block onboarding or features. Existing users can choose the setting without being forced through welcome again.
- Website: equal allow/refuse buttons and a footer preferences button. GPC or DNT blocks capture. Storage failures fail closed. A refusal in another tab stops later capture in this tab.
- App queue: memory only, at most 100 events; 50 per request; 24-hour expiry; four attempts maximum for transient failures; bounded backoff. Requests use an ephemeral URLSession with no cookies, cache or credential store; redirects are rejected.
- Disable: stop future events; clear app queue and cancel its pending request. A previously received event remains subject to project retention. There is no user identifier with which to reconstruct or target an individual's past events.
- Website: one best-effort request per allowed click, credentials omitted, no referrer header or redirects. No page views, session replay, SDK, cookies, browser identity or event queue.

## Dashboard definitions

Create a dashboard named **Lunavect — technical counters**, with total event counts (never the “unique users” aggregation):

| Tile | Calculation | What it does not prove |
| --- | --- | --- |
| Download-link clicks by source | Total `download_clicked`, breakdown `source`, split `target` | File transfer, install or unique visitor |
| Observed launches by version | Total `app_launched`, breakdown `app_version` and `os_major` | Installed base, DAU/MAU or time spent |
| Session navigation reliability | Counts of `session_navigation_result`, breakdown `client`, `provider`, `outcome`; failures / all attempts | Exact error cause or independently confirmed UI focus |
| GitHub asset requests | Separate snapshot report below, DMG and ZIP separately | New users; ZIP includes Sparkle updates |

No person funnels, retention/cohorts or user-journey dashboard: distinct IDs identify events, so PostHog's “unique users” would misleadingly count events. Never calculate opt-in percentage from these events: refusals and the nonconsenting population are not measured. Browser downloads cannot be tied to an app launch. Do not infer that relationship from network addresses or timing.

## GitHub snapshots

The read-only collector uses an already authenticated GitHub CLI and writes local files. It never downloads release assets, modifies the repository, signs in, schedules itself or uploads reports:

```sh
python3 scripts/collect-github-metrics.py \
  --output /absolute/path/outside-the-repo/metrics/2026-09-27
```

For a later snapshot, add `--previous /absolute/path/to/earlier/summary.json`. Deltas compare stable asset IDs. A replaced or new asset has an unknown earlier count, not a manufactured zero. Draft releases are excluded; prereleases remain explicitly marked. Partial endpoint failures produce `null`/unavailable status and a failing exit code, never zero traffic.

GitHub traffic covers a short returned window; save snapshots regularly if history matters. No recurring job is activated by this change. Use actual returned start/end dates and do not sum overlapping unique counts. Referrers describe repository traffic, not sources for each asset request. Homebrew and direct GitHub downloads can bypass the website completely. Release engineering/test downloads inflate counters.

## Acceptance before production activation

Local tests and mock-network renders do not establish that a new PostHog project is receiving or retaining events correctly. In an isolated staging build/profile:

1. Inspect network traffic before a choice, after refusal and with a blank token: no PostHog request.
2. Allow, perform one known navigation success and failure, and inspect the real project. Only declared fields should appear; no automatic page view, IP/geo properties, person profile or user-linked sessions. Two distinct events must have different IDs. Disable and confirm further actions send nothing.
3. Website: allow, click a download link and confirm the coarse source/target; test refusal, GPC/DNT, reload and cross-tab refusal. Ensure the download itself works regardless of statistics.
4. Confirm and publish the actual retention, spending limit and privacy copy, then prepare the normal signed/notarized release with its own version. The currently installed app and widgets are not touched by these preparation checks.

Local automated commands:

```sh
swift test --jobs 2 --filter UsageAnalyticsTests
node --test Tests/Website/analytics.test.js
python3 -B -m unittest discover -s Tests/Scripts -p test_github_metrics.py
./scripts/check.sh
```

Optional UI exports use isolated preferences, a synthetic token and a mock transport:

```sh
LUNAVECT_PREVIEW_LANGUAGE=en LUNAVECT_RENDER_ANALYTICS=/absolute/path/to/renders \
  swift test --jobs 2 --filter UsageAnalyticsViewTests
```

Source references: [PostHog Capture API](https://posthog.com/docs/api/capture), [event deduplication](https://posthog.com/docs/data/events), [privacy controls](https://posthog.com/docs/product-analytics/privacy), [GitHub traffic](https://docs.github.com/en/rest/metrics/traffic), [release asset counters](https://docs.github.com/en/rest/releases/assets).
