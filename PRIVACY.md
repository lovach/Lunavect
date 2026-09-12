# Privacy and permissions

Lunavect processes session metadata, usage limits and activity on your Mac. It has no Lunavect account, analytics service or backend for uploading session data. This page describes the public app's data flows; it does not describe the separate privacy practices of Claude Code, Codex, GitHub or macOS.

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
| `~/Library/Application Support/Weekleft/Sessions/` | Session records, hidden sessions, ordering, resume launchers and hook configuration backups |
| `~/Library/Application Support/Weekleft/ClaudeStatusLine/` | Claude quota caches and the previous status-line configuration |
| `~/Library/Application Support/Weekleft/ConnectionSetup/` | Commands used to install or sign in to an official client |
| `~/Library/Application Support/Weekleft/QuotaProbe/` | Isolated working directory for Claude's `/usage` command |
| `~/Library/Application Support/Weekleft/activity-details.json` | Project and session activity breakdowns |
| `~/Library/Group Containers/<TEAM_ID>.com.lunavect.shared/Weekleft/` | The signed app's shared quota snapshot, aggregate activity and widget selection data |

The app and widget also use macOS preferences. Builds without an available App Group use the Application Support directory for shared files. `<TEAM_ID>` depends on the signing team; it is not a folder name to paste literally.

Connecting Claude adds Lunavect event handlers and a status-line command to Claude's `settings.json`. Connecting Codex adds event handlers to `hooks.json`. Default locations are `~/.claude` and `~/.codex`; the app respects `CLAUDE_CONFIG_DIR` and `CODEX_HOME` when configured in its environment. Codex may require you to approve new handlers through `/hooks`.

Before editing client configuration, Lunavect saves a backup and preserves unrelated settings and handlers. A backup can include other values already present in that configuration file; treat it as private, just like the original. Disconnect removes Lunavect's handlers and restores its saved previous Claude status line when applicable. While connected, the status-line bridge forwards its input to the previous status-line command, if one existed; that command and other preserved handlers retain their own behavior, including any network access.

Lunavect creates its data directories and sensitive data files with owner-only permissions where it writes them. These files are local data, not an encrypted vault. Other software running as your macOS user may be able to read them.

## Network requests

| Action | Destination and data |
| --- | --- |
| Checking for or downloading an app update | GitHub and its download infrastructure. Normal request information, such as an IP address and app/updater headers, reaches those servers. Lunavect does not attach session data or activity history. |
| Installing an official client from the connection guide | The provider's HTTPS installer and any services that installer uses. The guide shows the installer source before launch. |
| Signing in or refreshing usage through an official client | The client's provider, under that client's authentication and network behavior. |
| Opening a documentation link or submitting an issue | Your browser and the destination you choose. Attachments are sent only if you submit them. |

Automatic update checks and downloads can be turned off in **Settings → Updates**. This does not disable the official clients' own network activity. Lunavect's menu bar and widgets read local state, but fresh account allowances require the relevant client to reach its provider.

## Permissions and optional features

| Capability | When used |
| --- | --- |
| Read local client files and edit client configuration | After connecting a provider; the connection guide explains its handlers and status-line changes |
| Notifications | If you enable alerts for session completion or requests for input |
| Launch at login | If you enable it in Settings |
| Privileged keep-awake helper | Only for the optional experimental closed-lid mode, with macOS approval |

The public app does not request Screen Recording or Accessibility permission to read session state or quotas. The main app is not sandboxed; the WidgetKit extension is sandboxed and reads the shared data. A permission error is shown as a source or setup problem, not as zero usage.

## Disconnecting and deleting data

Disconnect providers in **Settings → Connections** before removing Lunavect so it can remove its event handlers and restore the previous Claude status line. Disconnecting does not sign you out of the official clients, delete their conversations or erase Lunavect's existing history.

Quit Lunavect and remove the app, or use the [Homebrew uninstall command](docs/installation.md#uninstall). Preferences and data remain for a later installation. To remove those as well, first disconnect and quit, then remove only the Lunavect data locations listed above and the `com.weekleft.app` preferences. Review any backups before deleting them. Do not delete `.claude` or `.codex` to uninstall Lunavect; those belong to the official clients.

Public screenshots use sample data. Before reporting a problem, remove personal titles, paths and credentials from screenshots and logs. For sensitive findings, use the [private security reporting route](SECURITY.md).

[Installation](docs/installation.md) · [Connections](docs/connections.md) · [Activity](docs/activity.md)
