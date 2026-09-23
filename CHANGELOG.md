# Changelog

## 0.1.9 — 2026-09-23

- Codex's internal memory agent no longer shows up as a working session or makes Connections report an incomplete Codex session catalog. Codex consolidates its memories with an agent that works in `~/.codex/memories`; it reports events like a task, but it is not a thread you can open.

## 0.1.8 — 2026-09-23

- Widget registration is re-confirmed again 2 and 10 minutes after launch. A confirmation that coincided with post-update cleanup could leave desktop widgets showing placeholders until the next launch; the later confirmations happen after the cleanup has settled.

## 0.1.7 — 2026-09-23

- Desktop widgets recover on their own when macOS loses track of the widget extension after an install, update or extension restart. Each launch re-confirms the installed widget registration after 5 and 30 seconds, without restarting the extension or changing widget settings; the local installer retires the previous copy before its final registration.
- Lower background CPU use: session events, Claude Desktop titles and Codex subagent origins are no longer decoded again when their files have not changed, unchanged Codex journals are not reopened, and the Codex process search runs at most every four seconds. A closed Settings window no longer keeps recomputing statistics.
- Opening a Claude Code or Codex session that runs in Terminal or iTerm2 brings its own tab to the front and closes the session panel. Lifecycle hooks record only the terminal device; macOS asks once for Automation access. A terminal that is not running is never launched for this, and Desktop sessions are never matched to a CLI in the same folder.
- A Codex CLI bundled inside a desktop application is recognized as a terminal client when it runs in a terminal.
- A Claude CLI launched through a command inside another Claude or Codex task stays out of the session list, counters, notifications and activity.

## 0.1.6 — 2026-09-22

- Clear stale menu-bar waiting counts during system event tracking as soon as a session resumes.
- Reduce whole-panel updates while scrolling long session lists, preserving current gesture hit testing.
- Recognize segmented Codex rollout filenames so working desktop tasks remain visible.
- Restore installed widget-host registration after removing temporary build registrations.

## 0.1.5 — 2026-09-21

- Recover the installed widget extension registration after automatic and manual app updates, then request fresh timelines without resetting widget settings. macOS still schedules widget refreshes.
- Let expired session statuses leave the menu-bar count even while local event reads are failing or still pending.
- Keep confirmed internal Codex agents out of user session lists, waiting counts, activity and notifications. Ordinary tasks and independent chats remain visible; provider history is preserved.

## 0.1.4 — 2026-09-14

- Remove the blue update dot from menu-bar artwork. Update notices remain actionable in the session panel and available in the tooltip and accessibility label.
- Recognize more Claude confirmation questions, including approval of a draft or changes and download requests containing inline filenames. Existing replies are not reprocessed.
- Advance animated dots one visible step at a time when a timer is delayed. Phrases change after two displayed cycles; dots keep their reserved width.

## 0.1.3 — 2026-09-14

- Refresh saved widget data when new timestamps arrive, including recovery from stale values. macOS still schedules WidgetKit updates.
- Prevent a previous Claude closing question from returning to the waiting count after that session resumes work.
- Recognize Claude context compaction as active work and show an explicit compaction status.
- Keep the session count inside a frozen menu-bar button and remove empty horizontal space around idle Claude artwork.
- Change activity phrases after two complete animated-dot cycles, restarting dots for each phrase; make phrases available in all three status styles.
- Expose icon appearance directly and compact the settings layout while preserving saved preferences.

## 0.1.2 — 2026-09-13

- Recognize explicit closing decision questions from Claude as awaiting input and include them in the waiting count.
- Preserve inferred questions across idle session polls until new work, a terminal state or the existing freshness limit supersedes them.
- Inspect the supported local Stop payload without saving the assistant response text. Recognition is conservative and may miss other wording.

## 0.1.1 — 2026-09-13

- Stable session ordering while the panel is open, consistent waiting counts and clearer navigation through long lists.
- More reliable Codex desktop session discovery and activity recovery, including supported CLI launchers.
- Compact menu-bar limits with icons and percentages, plus configurable countdowns and provider colors.
- Widget backdrop transparency from 0–100%, with removable backgrounds and optional native glass material.
- Clearer activity widgets with full duration values, persistent period context and compact overview limits.
- More space and intermediate scale labels for the overview chart; manual subscription dates stay in Settings.
- Empty Claude lifecycle-only launches stay out of session lists until actual task activity starts.
- Settings that preserve existing choices during upgrades, keep Lunavect in the menu bar and return directly to sessions.
- Safer data persistence, local history recovery and Keep Awake helper lifecycle, with expanded regression checks.


## 0.1.0 — First public release

- macOS menu-bar session overview for Claude Code and Codex, with one-client or two-client setup.
- Weekly and available five-hour usage allowances, reset times, and optional Claude model limits.
- Local activity statistics and WidgetKit limits, activity, and overview widgets.
- Session navigation, reordering, hiding, automatic return on new work, and optional idle hiding.
- Optional completion notifications, animated companions, and six interface languages.
- Developer ID distribution and signed GitHub update feeds.

### Known limits

Other Macs, subscription plans, and client versions still need validation. Widget refresh is controlled by macOS. Transparent widget backgrounds and closed-lid keep-awake are experimental. See docs/verification.md for the current evidence and remaining checks.
