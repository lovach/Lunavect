# Activity and desktop widgets

Activity shows available working time for Claude Code and Codex. It is a local estimate from session states and timing records, not token usage, CPU time or a billing meter.

## Choose a widget

| Widget | Sizes | Contents |
| --- | --- | --- |
| Limits | Small, medium | Weekly remaining allowances and optional five-hour values |
| Activity | Small, medium, large | Claude and Codex activity together, or one provider, for the selected period |
| Overview | Large | Remaining allowances, an activity chart and provider totals |

Right-click the desktop, choose **Edit Widgets** and search for **Lunavect**. Add the size you want. For an activity or overview widget, right-click the placed widget and choose **Edit Widget** to set its period and source.

The gallery inside Lunavect is a preview. Changing its content, size, period or source does not add a widget or change one already on the desktop. The add-widget guide explains the macOS steps; it does not place a widget automatically.

## Periods and sources

- **Day:** the current calendar day, by hour.
- **Week:** today and the six preceding days.
- **Month:** today and the 29 preceding days.

Periods use your current time zone. A daylight-saving transition can produce 23 or 25 hours in a day. Choose both providers or one; disabling a provider does not substitute another provider's data.

The peach series represents Claude and the blue series represents Codex. Each point is an hourly or daily total, not a cumulative total. Provider totals cover the displayed period. The current hour or day may still be incomplete.

## Reading the chart

In **Settings → Statistics**, hover over a point for its values or click to keep it selected. Arrow keys move the selection; Escape or the clear control returns to the period view. Selecting a point also narrows the project breakdown to that hour or day.

Below the chart, the app shows observed and recovered time, provider overlap and available project/session details. Search the breakdown by session, project or provider. Records without a reliable project association remain in the overall total rather than being assigned to a made-up project.

A missing observation is different from a known zero. The trend may connect known points across an internal gap, but that line does not create measured work in the gap. Leading or trailing unknown intervals are not extended as if observed. Check the history and data-accuracy section for source freshness and recovery details.

## What counts as work

Live collection counts a short interval only when a session is freshly reported as running at both ends. Waiting for input or permission, ready, idle, unknown, disappeared sessions and long observation gaps are not counted as observed work. Restarting the app or waking from sleep starts a new observation; it does not fill the gap.

A short task that starts and finishes between observations can be missed. Hidden sessions are still eligible for collection because hiding changes presentation, not whether a task is working.

Each provider's total counts its concurrent sessions once. The combined total counts time when at least one selected provider worked. For example, if Claude and Codex both run for ten minutes at the same time, each gets ten minutes and the combined total is ten minutes. The two provider totals can therefore add up to more than the combined total.

Project totals also merge overlapping sessions within a project. Different projects may overlap, so their totals are not necessarily additive. Peak hour describes the available records for the selected period; it is not a forecast or a measure of complete coverage.

## Recovering earlier history

Lunavect can recover recent timing records from local client logs, including work before its first observation. It marks recovered time with `≈`. These durations can be approximate and may include waiting; they are kept distinct from live observations.

Recovery uses available timing metadata from Codex session and archived-session logs and Claude project logs. It does not turn every conversation, file timestamp or unfinished task into measured work. Unsupported, inconsistent or incomplete timing records can be skipped. Client formats and the available files determine how much can be recovered.

Recovery runs on initial setup and when an importer update requires it. **Refresh history** retries against the stored import boundary. The history section shows the outcome and any limits; an empty import is not proof that no work happened.

## Storage and refresh

Aggregate activity is stored in `activity.json` beside the shared quota snapshot. It contains intervals, provider coverage and recovery metadata, without session titles or project paths. The project/session breakdown is stored separately in `~/Library/Application Support/Weekleft/activity-details.json`; it includes identifiers, titles, paths and intervals and is not copied into the widget's shared history.

History is limited to 35 days. Aggregate storage is also capped at 50,000 intervals; detailed storage at 2,000 records and 100,000 intervals. Busy histories can cover less time. Files are written atomically; a corrupt file is preserved rather than silently replaced with empty data.

The app normally saves aggregate activity once a minute and on ordinary quit. A crash can lose the latest unsaved interval. WidgetKit reads saved observations and does not poll the providers itself. macOS decides when a requested widget refresh runs, so a widget may lag behind the app.

Desktop placement and refresh across supported Macs remain separate compatibility checks. See [verification](verification.md) and [Apple's WidgetKit refresh guide](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date).

[Connections](connections.md) · [FAQ](faq.md) · [Privacy and storage locations](../PRIVACY.md)
