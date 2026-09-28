# Changelog

## Unreleased

### Activity, storage and widgets

- Recovered Claude history is rebuilt from message timestamps: a prompt starts a turn and the last answer or Stop hook ends it, like Codex tasks. Tool results, subagent, meta and compaction rows never start a turn, unanswered prompts and silences over 30 minutes are not counted, and neither is the wait for your answer to a question or a plan approval. Long autonomous turns count in full, as live work does. Recovered time keeps its `≈` mark. The import version changes, so existing history is re-imported automatically once; the re-import reads only logs that can hold records from before live observation started.
- "From available records" appears only when coverage was actually lost (read budget, unreadable or missing logs, symbolic links). Skipped individual records stay in the import report as information, and widgets no longer show the info badge.
- Live collection tolerates a slow observation of up to three poll steps plus 5 seconds. Sleep and wake always start a new measurement. Longer gaps in running work are counted under History and data accuracy instead of disappearing silently.
- Activity is written less often: history once a minute while work runs, project/session details every five minutes without a forced disk flush (flushed at quit and before the Mac sleeps), and phase changes after a 15-second quiet period. Changes that do not affect measured activity no longer rewrite files. Quitting waits at most 3 seconds for an unresponsive disk.
- An unreadable statistics file no longer stops collection for good: **Keep a copy and start over** keeps it beside the original and starts a new history. Only that button does this; **Refresh history** and connecting a provider leave the file untouched. Details stay below the read limit by dropping the oldest records first, overlapping detail intervals are repaired instead of discarding the breakdown, and abandoned temporary files are removed at launch.
- Quota updates no longer reload the activity widget; it reloads when its history or its shared settings change. The installed app re-confirms its widget registration 5 seconds and 2 minutes after launch. When another copy of Lunavect is installed, Settings → Widgets names it and asks you to keep one; the app still confirms its own widgets unless macOS uses the other copy's.
- **Find data from a previous installation** lists copies left by the App Group migration, with their paths and last changes, and can move them to the Trash. Copies written within the last week, which a development build may still use, are not offered. The privacy page lists these copies, recovery backups and the IDE bridge files.
- The glass widget background can be turned off without a rebuild through a hidden setting; it relies on a private macOS interface and blocks Mac App Store distribution.

### Navigation to sessions

- Opening a terminal session no longer selects an unrelated tab that macOS gave the closed session's terminal device. Lunavect checks that Claude or Codex still runs there first; iTerm2 also restores a minimized window. A session whose CLI binary an update replaced, or that runs under another file name, is not mistaken for a closed one, and the terminal behind Terminal's `login` (including Alacritty) is named.
- The first macOS permission prompt for controlling Terminal or iTerm2 can be answered without a false timeout: Lunavect asks before searching tabs and waits up to a minute. When both terminals run, they share the 10-second search.
- Ghostty, Warp, kitty, WezTerm, Alacritty, tmux, screen, ssh sessions and VS Code forks such as Cursor are named as not supported instead of Lunavect searching Terminal tabs. A Codex CLI without `TERM_PROGRAM` no longer opens Codex Desktop.
- A live session whose tab cannot be focused is reported as possibly open even while its CLI is missing or being updated.
- Editor navigation distinguishes a busy editor, a companion that is installed but not answering, an incompatible companion and a window macOS refuses to activate from a missing session, and names the JetBrains product. Every JetBrains 2026.2 IDE and EAP build is recognized.
- VS Code companion 0.1.2: reports its version, keeps its socket in your private temporary folder, recreates it after the folder is cleaned and warns when it cannot start. An editor started with a different `TMPDIR` (a shell profile, `nix develop`, devbox or none) is still found, as long as the socket folder is private to you. Settings → Connections shows when an installed companion is older than the bundled one. Reinstall the companion to receive these fixes. The JetBrains companion 0.1.2 is prepared in source; the bundled JetBrains installer stays 0.1.1 until it is rebuilt with the IntelliJ SDK.
- Stale editor connection records left by forced quits are removed after a day. Installed 0.1.0 and 0.1.1 companions keep working.

### Sessions

- Lunavect's own `/usage` quota check no longer appears as a Claude session. Its run could show "quotaprobe-00 · Input needed", raise the menu-bar waiting count, play a notification sound, add activity minutes, start automatic Keep Awake and speed up polling.
- Automatic hiding no longer fills Hidden sessions with finished or dormant Claude background tasks that `claude agents --all` keeps listing, or with sessions that ended before the panel showed them. The listing of such history no longer keeps hidden entries from expiring after 35 days.
- A subagent finishing can no longer raise a session's background task count, and an empty list no longer clears it; the end of each reply sets it. Commands moved to the background while running are counted. Sessions that started no background work no longer show a task badge.
- Closing Claude right after interrupting a reply no longer announces **Response ready**. A finished `claude -p` or Agent SDK reply is announced once even when its end and the session's end arrive together.
- A Claude session in a terminal or editor whose client was killed or crashed mid-reply shows **Stopped** at once instead of working or waiting for up to ten minutes, and no longer adds activity or holds Keep Awake. One failed session-list read no longer shows it working again, and resuming it with `claude --resume` starts **Idle** instead of repeating the killed reply.
- A hook event that arrives while a session list is being read is no longer overridden by that list, and one failed or slow read no longer empties the list. A project on a disconnected network volume no longer stalls reading the list.
- Hidden-session expiry and ordering cleanup wait until the session lists have answered, instead of running once without them after launch.
- Answered MCP forms return the session to working, and a background agent asking for input shows **Input needed**.
- A resumed or forked Claude session appears as **Idle** before its first prompt, and a hidden one is shown again.
- A system clock correction no longer hides every idle session at once.
- Session records that can no longer be read are kept aside for diagnosis and removed after a day instead of being read again on every refresh.
- If `claude agents --json` changes its format, Connections reports an unsupported response instead of showing an empty Claude list.

### Usage limits

- Limits are requested by window state instead of every five minutes. A verified value is reused for 15 minutes during work and an hour when idle; an exhausted window is not requested before its reset; one confirming request follows each reset; failures back off from 5 to 60 minutes. Finished Claude and Codex responses reported by hooks trigger a debounced request. Wake waits for the network. The same policy applies to Codex.
- A failed Claude `/usage` probe ends two seconds after its screen stops changing instead of keeping Claude Code open for 25 seconds, and reports a specific reason: limit reached, usage data failed to load, window not started, workspace trust required (previously shown as a sign-in problem) or subscription limits unavailable (API billing or no subscription sign-in).
- After a weekly reset, an unstarted window is shown as 100% with "Starts with the first request" instead of "Unsupported response format". An exhausted window shows 0% with its countdown and no asterisk; after a passed reset without new data every surface shows the same "Reset at HH:MM, waiting for the new window's first data".
- Codex plans without rate-limit windows show "No limits" instead of waiting forever; Codex's reached-limit flag counts as 100%.
- Connections and Limits explain when Claude Desktop sessions cannot update limits through the status line.
- `--probe` prints the result of a real `/usage` probe; `--usage-probe` prints its screen. `LUNAVECT_PROBE_DUMP_DIR` saves failed probe screens for diagnosis (opt-in).
- "Limit available again" is no longer sent up to a minute early. `/usage` shows resets truncated to the minute ("11:59pm" for a reset at midnight); Lunavect now stores the end of the shown minute, so a Claude window no longer shows a dash or counts as reset during that minute, and a saved `/usage` reading from an earlier version is read the same way. When two sources report the same reset, the later time counts.
- More `/usage` reset forms are understood instead of failing the probe: a date without a time, "in 2h 15m", "today/tomorrow at …", 12-hour times with a space or capitals, 24-hour times, abbreviated time zones such as "CEST", a reset on the percentage line and model blocks such as "Current week (Sonnet only)". An "Extra usage" block is no longer read as the weekly window. Dated resets in the daylight-saving change are handled like clock times: a repeated hour counts from its later occurrence, a skipped hour is rejected.
- A Claude status-line window without a reset time no longer discards the other window. "No model usage data available" is reported as usage data that failed to load, and a Claude Code path that became a folder is reported as missing at once.

## 0.2.4 — 2026-09-27

- Terminal navigation stays responsive while macOS selects a tab. Slow or cancelled requests stop cleanly and retain specific permission and timeout messages.
- VS Code and JetBrains companions clean up connections reliably when they close. VS Code cancels delayed focus requests, enforces bounded waits and handles workspace/path boundaries consistently. Bundled companions are version 0.1.1; reinstall them from Settings → Connections to receive these fixes.
- Local session metadata recovers after temporary read failures or restored file permissions. Shared state and editor connection files use bounded reads and reject invalid inputs without discarding the original files.
- Quota resets remain accurate near midnight, New Year and daylight-saving changes. Old replies cannot overwrite quotas after changing the Codex executable, and limit notifications use the same freshness rules as the display.
- Corrupt background-work counts cannot overflow session badges. Timed Keep Awake leases cannot be prolonged by moving the system clock backward.
- Removed the unreleased analytics experiment from source and website. Lunavect sends no session data or app usage statistics to its developer; download and repository statistics come only from GitHub.

Validation and remaining compatibility limits are recorded in [verification](docs/verification.md).

## 0.2.3 — 2026-09-26

- Added exact navigation to existing Claude Code and Codex terminal sessions in local VS Code and JetBrains 2026.2, including the Classic and Reworked JetBrains terminals.
- Added offline editor companions and a setup section under Settings → Connections. The app selects the session's project, window and tab, verifies the live process identity and waits for focus confirmation.
- Added workspace-aware routes for the official Claude Code and Codex extensions in VS Code. These routes have interface/contract coverage; authenticated provider-panel behavior has not yet been verified.
- Prevented IDE sessions from falling back to Apple Terminal or Codex Desktop. Closed tabs, missing companions and ambiguous windows now show editor-specific messages.
- Added companion protocol, origin, navigation and packaged-installer checks, plus translations in all six app languages.

Compatibility: this version supports local macOS editors. JetBrains AI Chat/ACP panels, other JetBrains versions and remote workspaces are not supported. See [IDE session setup](docs/ide-sessions.md).

## 0.2.2 — 2026-09-26

### Fixed

- Opening a running Claude Code session can recover its Terminal tab even when a detached hook has lost the terminal device. Each live session is matched by its own process, including multiple sessions in the same project.
- Apple Terminal navigation ignores exited tabs that still hold a reused terminal device and restores the correct minimized window. Ambiguous project matches no longer select an arbitrary tab.
- If macOS denies Automation access, the session panel explains which permission to enable. Missing tabs, timeouts and other terminal errors also have specific messages.

### Documentation

- Updated the README and website introduction.

## 0.2.1 — 2026-09-24

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
