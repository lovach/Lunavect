# Privacy and permissions

**Lunavect sends no session data or app usage statistics to us.** There is no telemetry, analytics identifier, automatic diagnostic upload or Lunavect account. Session metadata, usage limits and activity are processed and stored locally on your Mac.

We use only GitHub's download and repository traffic statistics. This page explains the app's local data and network requests; Claude Code, Codex, GitHub and macOS have their own privacy practices.

## Client access and sign-in

Lunavect uses the official clients already installed on your Mac. If a client is missing, the connection guide offers its official installer. Installation and sign-in start only when you choose those steps.

Sign-in runs through the official client in Terminal. The client handles authentication and stores its credentials. Lunavect does not ask for provider passwords or API keys and does not read the clients' credential stores. Its sign-in checks use the client's exit status and discard command output.

## What Lunavect reads and keeps

| Data | Purpose | Stored by Lunavect |
| --- | --- | --- |
| Remaining allowances, reset times and observation timestamps | Usage limits and widgets | Local quota caches and a shared snapshot |
| Provider, session ID, title, project path, client, state, tool name and event time | Session rows and navigation | Local session records |
| Working intervals and observation coverage | Activity charts | Aggregate history shared with the widget |
| Session titles, IDs, project paths and associated working intervals | Project and session breakdowns | A separate local activity file |
| Language, display choices, hidden and pinned sessions, ordering and manually entered subscription dates | Preferences | Local preferences and data files |

Session sources and history recovery inspect local client metadata and log files. Those files can contain conversations; Lunavect extracts the fields needed for session identity, state and timing. It does not save a copy of the conversation, reasoning text, tool arguments or tool output in its session and activity records. Local client file formats can change and are not all public APIs.

Aggregate activity and project/session details retain up to 35 days. Size limits can shorten that history. Configuration backups and preferences have separate lifetimes; the 35-day limit does not erase all Lunavect data.

## Local files and configuration changes

Some paths still use **Weekleft**, the original internal name, to preserve compatibility:

| Location | Contents |
| --- | --- |
| `~/Library/Application Support/Weekleft/Sessions/` | Session records, hidden sessions, ordering, resume launchers (removed after a day) and hook configuration backups. A session record that can no longer be read is kept aside as `*.json.corrupt-*` for diagnosis; it and unreadable records are removed after a day |
| `~/Library/Application Support/Weekleft/ClaudeStatusLine/` | Claude quota caches and the previous status-line configuration |
| `~/Library/Application Support/Weekleft/bin/LunavectHook` | A symbolic link to the running app's hook helper, named by client settings; it contains no data |
| `~/Library/Application Support/Weekleft/ConnectionSetup/` | Commands used to install or sign in to an official client |
| `~/Library/Application Support/Weekleft/QuotaProbe/` | Isolated working directory for Claude's `/usage` command |
| `~/Library/Application Support/Weekleft/activity-details.json` | Project and session activity breakdowns |
| `~/Library/Application Support/Weekleft/activity-archive.json` | Daily totals kept for Year and All time: per project folder name and session identifier, no titles or full paths |
| `~/Library/Application Support/Weekleft/token-ledger.json` | Tokens per session, model and day read from the local Claude and Codex logs, with the read position in each log; no prompts or replies |
| `~/Library/Application Support/Weekleft/tasks.json` | Tasks you created: their text, project folder, budget, state and the agent's last summary |
| `~/Library/Application Support/Weekleft/Worktrees/` | Copies of git projects that tasks work in, on their own `lunavect/` branches; removed when you accept a task's changes |
| `~/Library/Group Containers/<TEAM_ID>.com.lunavect.shared/Weekleft/` | The signed app's shared quota snapshot, aggregate activity and widget selection data |
| `~/Library/Application Support/Lunavect/IDEBridge/` | Descriptors of connected VS Code or JetBrains companions: process IDs, session ID and working directory |
| The IDE bridge socket directory (see [IDE sessions](ide-sessions.md)) | User-only Unix sockets of running companions, removed when the editor shuts down normally |

The app and widget also use macOS preferences. Builds without an available App Group use the Application Support directory for shared files. `<TEAM_ID>` depends on the signing team; it is not a folder name to paste literally.

A damaged file is kept beside the original as `<name>.corrupt-<time>-<id>`, and a history that could not be read and was replaced through **Keep a copy and start over** as `activity.json.unreadable-<time>-<id>`. They contain the same kind of data as the original and are not removed automatically.

Earlier installations can leave copies that the current app no longer reads. The App Group migration copies shared files instead of moving them, so these may remain:

| Location | Contents |
| --- | --- |
| `~/Library/Group Containers/group.com.weekleft.shared/Weekleft/` | Shared snapshot, aggregate activity and widget selection from builds before the signed App Group |
| `~/Library/Application Support/Weekleft/snapshot.json`, `activity.json`, `ActivitySelection/` | The same shared files from builds without an App Group (only these names; the other entries in that folder are current) |

In **Settings → Statistics → History and data accuracy**, **Find data from a previous installation** lists what exists, with each path and its last change, and can move it to the Trash. Lunavect looks only when you ask and never deletes these copies on its own. Only the exact locations above are offered, never the container the running copy uses, and a copy written within the last seven days is left out: `group.com.weekleft.shared` is also the live container of development builds, and Application Support is live for a build without an App Group.

Connecting Claude adds Lunavect event handlers and a status-line command to Claude's `settings.json`. Connecting Codex adds event handlers to `hooks.json`. Default locations are `~/.claude` and `~/.codex`; the app respects `CLAUDE_CONFIG_DIR` and `CODEX_HOME` when configured in its environment. Codex may require you to approve new handlers through `/hooks`.

Before editing client configuration, Lunavect saves a backup and preserves unrelated settings and handlers. A backup can include other values already present in that configuration file; treat it as private, just like the original. Backups are readable only by your user (mode 0600); copies made by older versions are restricted at launch. The rewritten file keeps its values but uses sorted keys and a final newline, see [how settings files are written](connections.md#how-settings-files-are-written). Disconnect removes Lunavect's handlers and restores its saved previous Claude status line when applicable. While connected, the status-line bridge forwards its input to the previous status-line command, if one existed; that command and other preserved handlers retain their own behavior, including any network access.

Lunavect creates its data directories and sensitive data files with owner-only permissions where it writes them. These files are local data, not an encrypted vault. Other software running as your macOS user may be able to read them.

## Network requests

| Action | Destination and data |
| --- | --- |
| Checking for or downloading an app update | GitHub and its download infrastructure. Normal request information, such as an IP address and app/updater headers, reaches those servers. Lunavect does not attach session data or activity history. |
| Installing an official client from the connection guide | The provider's HTTPS installer and any services that installer uses. The guide shows the installer source before launch. |
| Signing in or refreshing usage through an official client | The client's provider, under that client's authentication and network behavior. |
| Opening a documentation link or submitting an issue | Your browser and the destination you choose. Attachments are sent only if you submit them. |

Automatic update checks and downloads can be turned off in **Settings → Updates**. This does not disable the official clients' own network activity. Lunavect's menu bar and widgets read local state, but fresh account allowances require the relevant client to reach its provider.

## GitHub statistics only

The project uses GitHub's existing release-asset download counters and repository traffic reports: views, clones, referring sites and popular repository pages. These are GitHub platform statistics, not events sent by Lunavect. They do not tell us which sessions you open, which projects you work on, how often you launch the app or which features you use.

The Lunavect website has no analytics scripts, tracking cookies or analytics consent banner. GitHub hosts the website, repository and release downloads and receives normal web request information under [GitHub's privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement). App update requests also go to GitHub, as described above.

Download counts are requests for files, not a count of users or installations. Repeated downloads and updates can contribute to them. GitHub's repository traffic reports cover a limited period and do not provide a complete path from a referring site to a download or to app usage. See the [GitHub-only statistics guide](download-statistics.md) for the reporting scope.

## Permissions and optional features

| Capability | When used |
| --- | --- |
| Read local client files and edit client configuration | After connecting a provider; the connection guide explains its handlers and status-line changes |
| Automation (control Terminal or iTerm2) | When you open a Terminal or iTerm2 session from its row; macOS asks once, and a denial is managed in System Settings → Privacy & Security → Automation. See [sessions](sessions.md) |
| Notifications | If you enable alerts for session completion or requests for input |
| Launch at login | If you enable it in Settings |
| Privileged keep-awake helper | Only for the optional experimental closed-lid mode, with macOS approval |

The public app does not request Screen Recording or Accessibility permission to read session state or quotas; Automation is used only to bring a terminal tab to the front. The main app is not sandboxed; the WidgetKit extension is sandboxed and reads the shared data. A permission error is shown as a source or setup problem, not as zero usage.

## Disconnecting and deleting data

Disconnect providers in **Settings → Connections** before removing Lunavect so it can remove its event handlers and restore the previous Claude status line. Disconnecting does not sign you out of the official clients, delete their conversations or erase Lunavect's existing history.

Quit Lunavect and remove the app, or use the [Homebrew uninstall command](installation.md#uninstall). Preferences and data remain for a later installation. To remove those as well, first disconnect and quit, then remove only the Lunavect data locations listed above (including copies from earlier installations and the IDE bridge folder) and the `com.weekleft.app` preferences. If you installed a VS Code or JetBrains companion, uninstall it through the editor's plugin manager; replacing or removing the app does not remove editor plugins. Review any backups before deleting them. Do not delete `.claude` or `.codex` to uninstall Lunavect; those belong to the official clients.

Public screenshots use sample data. Before reporting a problem, remove personal titles, paths and credentials from screenshots and logs. For sensitive findings, use the [private security reporting route](https://github.com/lovach/Lunavect/blob/main/.github/SECURITY.md).

[Installation](installation.md) · [Connections](connections.md) · [Activity](activity.md)
