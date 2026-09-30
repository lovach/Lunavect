# Changelog

## 0.2.8 — Unreleased

### Limits for running sessions

- Two-finger click (or ⋯) on a Claude or Codex session: **Limit Usage…** stops it when the week reaches the level you type, and can continue it after the reset; **Continue Later…** continues it after the five-hour or weekly reset or at a set time.
- The level starts at today's share: the rest of the week spread evenly over the days to the reset.
- **Don't get cut off by the 5-hour window** (on by default): shortly before the five-hour window runs out the agent finishes its step and waits; after the window resets Lunavect tells it to continue, and the week's level still applies.
- Near the level the agent is asked to finish its step and write two lines, what is done and what is left; at the level its next action is refused and a new prompt is blocked with the reason, through the hooks Lunavect already installs. Nothing is killed: files and the conversation stay as they are. The **Tasks** card shows the agent's summary.
- The continuation ("Continue from where you stopped", or your own words) is typed into the session's own Terminal or iTerm2 tab once it is idle and not asking for a permission. When the agent has exited in that tab, Lunavect runs `claude --resume` or `codex resume` there; when the tab is closed, it opens a new Terminal window in the session's folder. For other apps a notification says what to write.
- When Codex hits its usage limit mid-answer, Lunavect asks whether to continue the session after the reset (Settings → General → **If a limit cuts work off**: Ask, Continue without asking, Do nothing). Claude Code 2.1.234 and later continues by itself after a claude.ai usage limit; Lunavect only presses Enter when the Mac slept through the reset and Claude Code waits for it, or offers to continue when Claude's own automatic continue is off or gave up.
- Notifications about a stopped session have **Continue now** and **+5%**; the question after a cut-off has **Continue after the reset** and **No thanks**.
- The **Tasks** tab lists limited, resting and planned sessions; a small symbol marks them in the session list.

### Agent Monitor

- **Agent Monitor** (status menu and Statistics) lists sessions with tokens, model, the share used by subagents, the estimated share of the weekly limit and the current pace, and shows each provider's week and hourly pace.
- Statistics gain **Where tokens went**: cache share, subagents, and projects and models weighted by price, which is roughly how a limit is spent. Tokens are read from the local Claude and Codex logs; the first pass reads them all once in the background.

### Statistics

- **Year** and **All time** join Day, Week and Month. Year is drawn by week; All time adapts to the amount of history (by day under two months, by week under a year, by month beyond). Both start at the week of the first record, so a short history is not squeezed into a corner of an empty year, and each source's line starts at its own first record. Hovering the chart shows that week's time per source and together.
- Daily totals are now kept without a time limit (about 1 KB a day). Once, Lunavect reads every Claude and Codex log still on the Mac and adds those days, marked ≈ as recovered.
- New cards: a **Calendar** of days with work (with the longest day and the average per day with work), **When you work** (the day as a 24-hour clock with each hour's work, shares of night, morning, afternoon and evening, and time per weekday; hovering an hour shows its time), **Projects** by time, **Agents waited for you** (answers, permissions and the typical wait, counted live from this version) and **Sessions** (count, average and longest). Hovering a calendar day shows its time.

### Limits

- A Codex limit lifted early by a manual usage-limit reset shows within an hour: while a Codex window is used up Lunavect now asks hourly and after session activity, not only at its scheduled reset. Before, the widget could keep showing 0% for days. Claude, whose limits have no manual reset, still waits for the reset; a refresh asks at any time.

### Widgets and subscriptions

- The limits widgets show the plan end date from Settings → Subscriptions as a compact icon and date: orange with the days left in the last week, red once it has passed. **Show plan end date** in Settings → Widgets turns it off.
- When the end date has passed but the provider still reports subscription limits, the plan was probably renewed, sometimes a day late: Settings → Subscriptions offers the old date plus a month or another date, and one notification says so.

### Sessions

- A Claude run in print mode (`claude -p`), which plugins and scripts start without a window, is shown as **Background run** with the app that started it (for example "Background run · Python"). It no longer counts as working, sends no notifications, is not activity and does not keep the Mac awake. Clicking it explains what it is and that it cannot be opened, instead of asking you to open a window that does not exist.

## 0.2.7 — 2026-09-28

### Limits

- Limits no longer show "Data is outdated" while Lunavect is simply waiting for its next scheduled check. Since 0.2.5 an idle provider is asked once an hour, but values were marked outdated after 15 minutes, so for most of every quiet hour Codex and Claude looked stale. A value is now outdated only when the app has missed its own schedule (70 minutes); a failed request still marks the provider at once.
- A window at 99.4 % used shows "1%" and is treated as available, the same way everywhere; only a window that shows 0 % counts as used up.
- Claude's weekly model limit (Fable) can be shown in widgets next to the five-hour value: **Show Fable limit** in Settings → Widgets and Settings → Limits (off by default). Settings keeps showing it as before.
- Notifications warn before the Fable weekly limit runs out, at the same threshold as the other limits, with its own switch in Settings → Notifications (on by default).

### Widgets

- After an update, the widgets could keep the previous version's values for hours: a widget process of the old build kept running, and macOS rejected every timeline from it ("Bundle version did not match"). Lunavect now finds and stops such a process even after the update moved or deleted its files, and it checks every 10 minutes that WidgetKit still accepts the installed widget. When it does not, Lunavect repairs the widget itself without a notification, at most once an hour.

### Editors

- Cursor and other editors built on VS Code (Windsurf, VSCodium and others) are supported like VS Code: clicking a session selects its terminal tab or its Claude Code or Codex panel. The editor is recognized from its own `product.json`, and messages name it ("Cursor"). Install the companion the same way: **Extensions → Install from VSIX**.
- The VS Code companion 0.1.3 reports the editor it runs in. Lunavect offers the update to installed 0.1.2 companions.

### Updates

- Cancelling or postponing the installer's authorization is no longer shown as a failed update check.

## 0.2.6 — 2026-09-28

### Limits

- The current `/usage` screen of a signed-in subscription is pinned by a test on a real capture: the session and weekly windows, the separate weekly Fable window, the usage breakdown and Usage credits are read correctly.
- When a Claude model's weekly limit (for example Fable) has less left than the weekly limit for all models, the limits popover shows it under Claude with its own meter; otherwise the popover is unchanged.
- When Claude Code is not signed in, the limits popover and the sessions panel say so with **Sign in again**, and one notification is sent when this starts; previously only Connections said it.

### Sessions

- Declining a permission no longer keeps a session at **Needs permission**: a request ends with its own tool result, a new tool call in the same context, the end of a subagent, the end of the turn or Claude's idle prompt. A request of one subagent is no longer cleared by another, and a newer "waiting" listing no longer turns **Needs permission** into a second waiting notification.
- A `/usage` check started by hand with the probe's command appears as **Service limit check**: it is not counted, sends no notifications, and clicking it explains how to close it.
- When a session cannot be opened, the message names where it runs (the terminal built into Claude or Codex, an unsupported terminal or another app) instead of a generic "tab not found".

### Editors

- Claude Code installed with npm is recognized in Terminal, VS Code and JetBrains (`claude.exe` inside the package, or `node`/`bun` running the package's script); other `node` programs are not sessions.
- The JetBrains companion 0.1.2 ships with the app: its socket follows your temporary folder and is recreated after cleanup, start-up failures are shown in the IDE, and a busy IDE answers "busy" instead of timing out. Lunavect offers the update to installed 0.1.1 companions.
- JetBrains sessions are always matched through the process chain, including a Reworked terminal tab whose process has no controlling terminal. PyCharm, WebStorm, GoLand and other JetBrains 2026.2 IDEs take the same path as IntelliJ IDEA.

## 0.2.5 — 2026-09-28

### Activity, storage and widgets

- Recovered Claude history is rebuilt from message timestamps: a prompt starts a turn and the last answer or Stop hook ends it, like Codex tasks. Tool results, subagent, meta and compaction rows never start a turn, unanswered prompts and silences over 30 minutes are not counted, and neither is the wait for your answer to a question or a plan approval. Long autonomous turns count in full, as live work does. Recovered time keeps its `≈` mark. The import version changes, so existing history is re-imported automatically once; the re-import reads only logs that can hold records from before live observation started.
- "From available records" appears only when coverage was actually lost (read budget, unreadable or missing logs, symbolic links). Skipped individual records stay in the import report as information, and widgets no longer show the info badge.
- Live collection tolerates a slow observation of up to three poll steps plus 5 seconds. Sleep and wake always start a new measurement. Longer gaps in running work are counted under History and data accuracy instead of disappearing silently.
- Activity is written less often: history once a minute while work runs, project/session details every five minutes without a forced disk flush (flushed at quit and before the Mac sleeps), and phase changes after a 15-second quiet period. Changes that do not affect measured activity no longer rewrite files. Quitting waits at most 3 seconds for an unresponsive disk.
- An unreadable statistics file no longer stops collection for good: **Keep a copy and start over** keeps it beside the original and starts a new history. Only that button does this; **Refresh history** and connecting a provider leave the file untouched. Details stay below the read limit by dropping the oldest records first, overlapping detail intervals are repaired instead of discarding the breakdown, and abandoned temporary files are removed at launch.
- Quota updates no longer reload the activity widget; it reloads when its history or its shared settings change. The installed app re-confirms its widget registration 5 seconds and 2 minutes after launch. When another copy of Lunavect is installed, Settings → Widgets names it and asks you to keep one; the app still confirms its own widgets unless macOS uses the other copy's.
- **Find data from a previous installation** lists copies left by the App Group migration, with their paths and last changes, and can move them to the Trash. Copies written within the last week, which a development build may still use, are not offered. The privacy page lists these copies, recovery backups and the IDE bridge files.
- The glass widget background can be turned off without a rebuild through a hidden setting; it relies on a private macOS interface and blocks Mac App Store distribution.
- After the clock is set far ahead and corrected, activity keeps being recorded instead of stopping until real time catches up.
- On a slow disk, activity saving keeps only the newest waiting state: memory no longer grows with a backlog and quitting writes the last state within its time limit. Retention trims only expired history from its start instead of scanning all of it on every observation.
- The small limits widget and the combined widget show a plan without limits as ∞, a used-up or not yet started window like the menu bar, and no false warning mark.
- A failed App Group migration removes only the copies it made, so the next installation can migrate again.

### Navigation to sessions

- Opening a terminal session no longer selects an unrelated tab that macOS gave the closed session's terminal device. Lunavect checks that Claude or Codex still runs there first; iTerm2 also restores a minimized window. A session whose CLI binary an update replaced, or that runs under another file name, is not mistaken for a closed one, and the terminal behind Terminal's `login` (including Alacritty) is named.
- The first macOS permission prompt for controlling Terminal or iTerm2 can be answered without a false timeout: Lunavect asks before searching tabs and waits up to a minute. When both terminals run, they share the 10-second search.
- Ghostty, Warp, kitty, WezTerm, Alacritty, tmux, screen, ssh sessions and VS Code forks such as Cursor are named as not supported instead of Lunavect searching Terminal tabs. A Codex CLI without `TERM_PROGRAM` no longer opens Codex Desktop.
- A live session whose tab cannot be focused is reported as possibly open even while its CLI is missing or being updated.
- Editor navigation distinguishes a busy editor, a companion that is installed but not answering, an incompatible companion and a window macOS refuses to activate from a missing session, and names the JetBrains product. Every JetBrains 2026.2 IDE and EAP build is recognized.
- VS Code companion 0.1.2: reports its version, keeps its socket in your private temporary folder, recreates it after the folder is cleaned and warns when it cannot start. An editor started with a different `TMPDIR` (a shell profile, `nix develop`, devbox or none) is still found, as long as the socket folder is private to you. Settings → Connections shows when an installed companion is older than the bundled one. Reinstall the companion to receive these fixes. The JetBrains companion 0.1.2 is prepared in source; the bundled JetBrains installer stays 0.1.1 until it is rebuilt with the IntelliJ SDK.
- Stale editor connection records left by forced quits are removed after a day. Installed 0.1.0 and 0.1.1 companions keep working.
- A stopped Claude session no longer opens another Claude session that received the same terminal device: when the session's hook recorded its process, only that process identifies the tab.
- The VS Code companion recognizes the Claude Code panel by the tab type VS Code reports, so opening such a session no longer ends with a false "VS Code did not respond in time".

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
- A subagent finishing now reaches Lunavect: its list can lower a session's background task count and never raises it.
- **Response ready** and error notifications are announced once, even when Claude's session list still reports the session as busy while Stop hooks run.
- A new session that Lunavect first sees already waiting for permission or input, or already answered, is announced. Sessions present at launch stay silent.
- A burst of hook events causes one read of the session records instead of about two reads per event.

### Usage limits

- Limits are requested by window state instead of every five minutes. A verified value is reused for 15 minutes during work and an hour when idle; an exhausted window is not requested before its reset; one confirming request follows each reset; failures back off from 5 to 60 minutes. Finished Claude and Codex responses reported by hooks trigger a debounced request. Wake waits for the network. The same policy applies to Codex.
- While a window is used up, no request runs before its own reset, even when the other window's reset passes meanwhile; previously an unreadable screen at 100% could bring a visible probe every hour until the weekly reset. Claude's "limit reached" screen pauses requests until the earliest known reset. Wake and a restored network retry at once only after a network, timeout or loading failure; a workspace trust question, sign-in, API billing or unsupported screen keeps its backoff until you refresh. A request right after a reset that still shows the old window keeps "Reset at HH:MM, waiting for the new window's first data" and is repeated after 5, 10, 20 minutes and so on. A timer, reset or session event that arrives during another refresh is evaluated after it instead of being dropped.
- A `/usage` screen still loading at the deadline is reported as a timeout instead of "window not started". Values Claude Code shows next to "Could not refresh usage data" or "Failed to load usage data" are no longer saved as a fresh reading. Cursor and spinner redraws no longer keep a failed probe open for 25 seconds.
- A failed Claude `/usage` probe ends two seconds after its screen stops changing instead of keeping Claude Code open for 25 seconds, and reports a specific reason: limit reached, usage data failed to load, window not started, workspace trust required (previously shown as a sign-in problem) or subscription limits unavailable (API billing or no subscription sign-in).
- After a weekly reset, an unstarted window is shown as 100% with "Starts with the first request" instead of "Unsupported response format". An exhausted window shows 0% with its countdown and no asterisk; after a passed reset without new data every surface shows the same "Reset at HH:MM, waiting for the new window's first data".
- Codex shows "No limits" when it reports unlimited credits without rate-limit windows, instead of waiting forever. An answer without any known window otherwise stays unknown and is asked again with the failure backoff, not every five minutes. Codex's reached-limit flag counts as 100%.
- Connections and Limits explain when Claude Desktop sessions cannot update limits through the status line.
- `--probe` prints the result of a real `/usage` probe; `--usage-probe` prints its screen. `LUNAVECT_PROBE_DUMP_DIR` saves failed probe screens for diagnosis (opt-in).
- "Limit available again" is no longer sent up to a minute early. `/usage` shows resets truncated to the minute ("11:59pm" for a reset at midnight); Lunavect now stores the end of the shown minute, so a Claude window no longer shows a dash or counts as reset during that minute, and a saved `/usage` reading from an earlier version is read the same way, including model limits that a 0.2.4 snapshot kept next to status-line data. When two sources report the same reset, the later time counts.
- More `/usage` reset forms are understood instead of failing the probe: a date without a time, "in 2h 15m", "today/tomorrow at …", 12-hour times with a space or capitals, 24-hour times, abbreviated time zones such as "CEST", a reset on the percentage line and model blocks such as "Current week (Sonnet only)". An "Extra usage" block is no longer read as the weekly window. Dated resets in the daylight-saving change are handled like clock times: a repeated hour counts from its later occurrence, a skipped hour is rejected.
- A Claude status-line window without a reset time no longer discards the other window; at 0% it is shown as not started ("Starts with the first request"), like the same state from `/usage`. "No model usage data available" is reported as usage data that failed to load, and a Claude Code path that became a folder is reported as missing at once.
- When Claude Code in Terminal is not signed in to a Claude account, its `/usage` shows "API Usage Billing" and no plan limits. Lunavect now says that Claude Code is not signed in and how to sign in (**Sign in again**, or `claude` then `/login` in Terminal), instead of "the client's response format is not supported".
- A failed `/usage` check keeps its reason in Connections instead of reporting the connection as working after a few seconds.
- An unfamiliar block after an inactive window no longer gives that window its reset time or rejects the whole screen.
- Running an older copy of Lunavect alongside no longer shifts saved reset times by a minute each time.
- Lunavect's status line waits at most 10 seconds for your previous status line command and reads at most 1 MB from Claude.
- Connections explains why checks are unavailable while limits are updating, says when a check can run again, and no longer promises an update next to an unsupported response. The limits popover's refresh button explains why it is off.

### Keep Awake and connections

- Keep Awake shows when the system helper is still registered from an earlier build or signing team and macOS does not start it, instead of reporting a generic timeout. **Renew registration** repairs it; if macOS refuses, the panel offers the maintenance command of this installation and Login Items. The first lease in a new build pings the helper for three seconds and renews its registration once when it does not answer.
- The helper's launch definition no longer asks launchd to restart it after every exit. A helper whose program is missing no longer makes launchd retry every 30 seconds indefinitely. The first launch of this build renews the registration so installed helpers pick up the new definition. A helper that cannot restore sleep keeps retrying while it runs, and Lunavect starts a new helper instance when the previous one stops answering during a lease.
- Claude Code and Codex settings name the hook helper through a link in Lunavect's support folder that every launch points at the running app. Moving, renaming or updating Lunavect no longer leaves the status line and event handlers pointing at a missing file. A copy that macOS runs from a temporary download location asks to be moved to Applications instead of writing its temporary path. Existing entries move to the link at the next launch, and the session panel says so.
- Launch repair changes only Lunavect's own entries that point elsewhere. It no longer adds back an event handler you removed, and `disableAllHooks` is shown as paused instead of a failed repair after moving the app.
- **Turn off events** is shown as your choice with a **Turn on events** button, not as unfinished setup. A command pointing at a deleted file is shown with its path.
- Settings files with comments or trailing commas are left untouched. Rewritten files end with a newline, are flushed to disk before they replace the original, and keep a link to a settings file even when its file does not exist yet. Disconnecting keeps a settings file Lunavect created, without its entries. Older backups of client settings become private to your user.
- A second installed copy of Lunavect is reported on the session panel. `weekleft://` links open the same pages as `lunavect://`. Updates are checked once a day instead of every hour.
- After an update, a helper that stopped while sleep was turned off is started once to restore normal sleep before its registration is renewed. The panel says that sleep is off instead of claiming the helper is retrying.
- When macOS refuses to renew the helper registration, the panel keeps the manual repair steps instead of offering a retry that repeats the refusal. A refused connection renews the registration at most once per launch.
- In automatic mode Keep Awake reads the helper status at most every 5 seconds instead of on every session update.
- A malformed hook command no longer opens Lunavect's window, and `--probe` and `--usage-probe` exit with an error after a timeout.
- Resetting settings is not applied partly when one part fails. VoiceOver reads each connection step with its state. Spanish uses the informal *tú* throughout.

### Development and checks

- Version 0.2.5 (192), so a local build of this branch cannot be mistaken for 0.2.4 (191).
- Tests can no longer reach the user's applications, clipboard, Finder, client CLIs, login items or widget registration: navigation, process launches and system features refuse under XCTest unless a live test opts in, and every write guard now covers directory creation, recovery moves and cleanup. Native fixture cleanup never signals a reused process ID.
- `check.sh` verifies that the app, widget and both helpers contain arm64 and x86_64 slices. The iCloud copy check covers `.github`, `docs` and `design`.
- Packaging tools refuse test overrides without `--test-fixture`, and release preflight refuses a VERSION that differs from `project.yml`.
- The weekly native render comparison fails when its baseline cannot be compared instead of passing without a comparison.
- The privacy notes list the Automation permission used to focus Terminal and iTerm2 tabs.

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
