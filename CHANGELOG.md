# Changelog

## Unreleased

### Fixed

- A Claude session waiting for its background tasks no longer disappears from the panel, and a finished session stays visible for the whole automatic hiding interval instead of a few seconds. Both happened when a status-bar script also recorded the session or when Claude's session list was polled after the reply.

## 0.2.0 — 2026-09-24

### New

- **Background tasks.** A small capsule on a Claude session shows how many background commands, subagents, monitors and workflows it is running, while Claude is still thinking and after it replies. A reply that leaves such work running stays **In background** instead of **Response ready**, replies to task events stay silent, and one notification arrives after the last task finishes. Dev servers and log followers do not hold the notification. Lunavect adds a `SubagentStop` handler to Claude Code automatically on launch.
- **Why a turn failed.** When a Claude Code turn ends with an API error, the session and a new **Errors** notification name the reason: limit reached (with the time it is available again), can't reach Claude, service error, sign in again or account issue.
- **Limit alerts.** **Limits** notifications warn once when a five-hour or weekly allowance of Claude or Codex drops below 5, 10, 20 or 25% (10% by default) and announce its return at the reset. Only fresh values count.
- **No network.** Working sessions show **No network** instead of **Thinking** while the Mac has been offline for more than 10 seconds.

### Improved

- Times, weekdays and percentages follow the Mac's region and 12- or 24-hour clock in every language, and look the same in the menu bar, popover, widgets and Settings. Languages Lunavect does not support fall back to English everywhere.
- The session panel: Return and swipe cannot open a session twice; a notification click opens a known session at once; an opening error appears in the panel; reopening the panel returns to current sessions; refresh buttons no longer dim with every background poll; the row tooltip shows the status as displayed and the full folder; **Command-Delete** hides the focused row; Control-click on a menu bar item opens its menu; VoiceOver announces pinned rows.
- Automatic Keep Awake shows **Paused** after a battery, heat or helper stop and resumes by itself after five minutes, or at once when the stop conditions change. A slow helper reply no longer re-registers the helper, and restoring base settings never applies only part of them.
- Recording the panel shortcut listens only in Settings and refuses standard commands such as Command-C and Command-W.
- The limits popover follows the app theme and says when it waits for the network; Settings → Limits shows the date of older data; widget labels and meters are stronger with Increase Contrast.
- Launch no longer reads old Codex session journals; hidden-session records, resume launchers and temporary files no longer grow without bound.

### Fixed

- Activity widgets no longer show the outdated badge while Lunavect observes normally.
- Disconnecting a client after Lunavect reinstalled its handlers over edited settings now removes every Lunavect handler; client settings are written without escaped slashes.
- A Claude usage reset that has just passed no longer fails the `/usage` probe, and an idle session's older quota can no longer replace a newer one.
- Hook events larger than 1 MB keep their lifecycle transition; an MCP request to open a link counts as waiting for input.
- The German translation consistently uses the formal form.

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
