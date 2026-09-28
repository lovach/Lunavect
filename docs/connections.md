# Connecting Claude Code and Codex

Connect either provider or both in **Settings → Connections**. Lunavect checks each provider separately: finding the client, confirming sign-in, configuring local events and receiving fresh usage data are different steps.

## Requirements

- **Claude:** Claude Code CLI. Claude Desktop alone cannot supply the CLI usage integration. Sessions started from Claude Desktop run Claude Code without its terminal interface: hooks work, but the status line never runs there, so limits come only from `/usage` (see below).
- **Codex:** the official Codex client and an available Codex CLI, either installed separately or bundled with the macOS app.
- An account mode for which the official client exposes the requested allowances. A successful sign-in does not guarantee that weekly or five-hour limits are available.

The guide reuses an existing installation and sign-in. If a step is already complete, it moves to the next one.

## Connect a provider

1. Open **Connect Claude** or **Connect Codex**.
2. If the client is missing, review the official installer source and choose the installation step. It runs in Terminal. Simply opening the guide does not install anything.
3. If sign-in is needed, start the official client's login flow. Complete it in Terminal or your browser, then return to Lunavect. Authentication stays with that client.
4. Review the local changes and enable limits and sessions. Lunavect adds its event handlers; Claude also gets a status-line command. Existing unrelated handlers are preserved and configuration is backed up.
5. For newly installed Codex handlers, open `/hooks` in Codex and approve the Lunavect commands when requested. A configuration file alone does not prove that events have arrived.
6. Follow any remaining diagnostic action. Claude may need its first `/usage` launch completed. Run a task to check session events and compare available quotas with the official client.

The guide checks progress while open. If an external window was closed or setup did not finish, retry the incomplete step. It does not need to replace a working sign-in or reinstall existing handlers just because a quota request failed.

## Where the data comes from

| Provider | Usage limits | Session state and titles |
| --- | --- | --- |
| Claude Code | The official CLI's `/usage` output and `rate_limits` delivered to the status-line command | Local lifecycle hooks, available client session information and title metadata |
| Codex | `account/rateLimits/read` through the local Codex app-server | Available runtime state, lifecycle hooks and local session metadata; log-based fallback where needed |

`/usage` shows resets truncated to the minute: "Resets Sep 27 at 11:59pm" for a reset at 00:00:00. Lunavect stores the end of the shown minute, so a window is not shown as reset and its return is not announced before the reset has certainly happened; the same reset from the status line gives the same time. Resets shown as a date only ("Sep 28"), relative ("in 2h 15m"), as "today/tomorrow at …", in 24-hour time or with an abbreviated zone ("CEST") are read the same way, to the end of the shown day or unit and never later than the window's length from the reading. A time in a repeated daylight-saving hour is read as its later occurrence; a time in a skipped hour is rejected. A status-line window at 0 % without a reset time has not started yet and is shown like the same `/usage` block; a used window without a reset time is treated as absent. The other window is kept either way.

Claude status-line quotas have a receipt time but no server observation timestamp. They remain marked as saved observations; recent `/usage` results take precedence. Recognized repeated status-line payloads do not advance their receipt time, and a lower value for the same limit window from another session (an idle session's older response, re-sent when Claude re-runs its status line) does not replace a newer observation.

## When limits are refreshed

A Claude `/usage` probe starts Claude Code for a few seconds, and a Codex request starts its app-server, so Lunavect asks only when the window state calls for it. A five-minute timer only evaluates this policy:

| State | Shown | Automatic request |
| --- | --- | --- |
| Current value | Remaining percentage and countdown; `*` after 15 minutes | After 15 minutes while sessions are active (an event within the last hour), otherwise after an hour |
| 0 % remaining, reset ahead | `0%` and the countdown, without `*` | None before the saved reset, also when the other window's reset passes meanwhile |
| Reset passed, no newer data | A dash and "Reset at HH:MM, waiting for the new window's first data" | One request at the latest passed reset plus a grace (30 s after the end of the minute `/usage` showed; 5 s for exact status-line and Codex times); an answer that still shows the passed reset is repeated with the backoff |
| Window not started (0 % used, no reset) | 100 % and "Starts with the first request" | After session activity, otherwise hourly |
| Codex with unlimited credits and no window | ∞ and "No limits" | Hourly |
| Last request failed, or an answer without any known window | Last value with `*` and the specific reason, or a dash | Backs off 5, 10, 20, 40, then 60 minutes; "limit reached" waits for the earliest known reset |

A finished response reported by the lifecycle hooks triggers a request 90 seconds after the last event of a burst when the data is older than two minutes; hooks also run for Claude Desktop sessions. After wake Lunavect waits four seconds and asks only if the network is up. Wake and a restored connection restart the backoff after a network, timeout or loading failure; a workspace trust question, sign-in, API billing or unsupported screen keeps its backoff until you refresh. A timer, reset or session event that arrives while another refresh runs is evaluated after it. **Refresh limits** in the menu and the limits panel and **Refresh data** in Connections always ask, at most once per 30 seconds per provider. **Refresh sessions** in the session panel reads sessions only and never starts a quota probe.

Local catalog entries and titles are not evidence that a session is working. Fallback readers depend on client file formats, so a client update can affect detection. See [sessions](sessions.md) for state handling and navigation limits.

## Local changes

Default client configuration files are `~/.claude/settings.json` and `~/.codex/hooks.json`. Lunavect respects `CLAUDE_CONFIG_DIR` and `CODEX_HOME` when set in the app's environment. Advanced connection settings provide a manual Codex executable path when automatic discovery is insufficient.

Hooks invoke the bundled `LunavectHook` helper. It keeps session identity, project, client, state, tool name and timestamps, not the prompt or tool arguments. The Claude status-line handler stores quota values rather than the full input payload. Setup launchers contain commands and paths, not copied authentication tokens.

For all storage paths, backups, permissions and network behavior, see [Privacy and permissions](privacy.md).

## Troubleshooting

- **Client not found:** use the guide's installation action or check the executable path in advanced settings.
- **Not signed in:** complete the official client's login step, then retry its status check.
- **No session events:** check handler installation and, for Codex, handler approval. An already open client session may need to be reopened.
- **Quota unavailable:** follow the selected provider's diagnostic action. Check whether the official client itself shows that allowance. Missing values remain unavailable.
- **Claude asks to trust a folder:** Claude Code shows its workspace trust question for Lunavect's probe folder (`~/Library/Application Support/Weekleft/QuotaProbe`) until it is answered once. **Finish Claude Code setup** opens `/usage` in that folder in Terminal; Lunavect never answers the question itself.
- **Subscription limits unavailable:** `/usage` shows only the session cost panel when Claude Code is not signed in with a subscription or bills through an API key. Sign in with the subscription account in Claude Code.
- **Limit reached or usage data failed to load:** the saved values stay; Lunavect asks again after the earliest known reset (limit reached) or after the backoff. Values Claude Code shows next to "Could not refresh usage data" are its cached ones and are not saved as a new reading.
- **Claude Desktop only:** when recent Claude sessions all ran in Claude Desktop and the status line has not reported since, Connections and the Limits page note that limits refresh through `/usage`. This is expected, not a fault.
- **Diagnosing the probe:** `Lunavect.app/Contents/MacOS/Lunavect --probe` prints the result of one real `/usage` probe (or its typed reason), the saved status line and Codex; `--usage-probe` prints the plain screen text first. With `LUNAVECT_PROBE_DUMP_DIR=<folder>` set, the plain text of a failed probe screen is saved there (mode 0600). Nothing is saved otherwise.
- **Offline or stale:** the last observation keeps its original timestamp. When connectivity returns, Lunavect retries; network availability alone does not prove that the provider is responding.

## Disconnect

Disconnect a provider in **Settings → Connections** before removing Lunavect. This removes its event handlers and restores the saved previous Claude status line when applicable. Unrelated client settings and handlers remain in place.

If cleanup fails, the app reports the error; resolve it before deleting the app. Disconnecting does not sign you out of the official client, delete its conversations or erase Lunavect's existing history. Removing only the app does not undo handler configuration. See [uninstalling](installation.md#uninstall).

## Interface references

- Claude Code: [setup](https://code.claude.com/docs/en/setup), [authentication](https://code.claude.com/docs/en/authentication), [status line](https://code.claude.com/docs/en/statusline), [hooks](https://code.claude.com/docs/en/hooks).
- Codex: [CLI](https://learn.chatgpt.com/docs/cli), [authentication](https://learn.chatgpt.com/docs/auth), [app-server](https://learn.chatgpt.com/docs/app-server), [hooks](https://learn.chatgpt.com/docs/hooks).

These references describe the clients' interfaces, not a certification or endorsement of Lunavect. Current installation and compatibility evidence is recorded in [verification](verification.md).

## Sessions in editors

Lunavect 0.2.3 includes local companions for VS Code and JetBrains 2026.2. Install the companion from Settings → Connections → Sessions in editors to select the existing Claude or Codex terminal tab. See [IDE session setup and compatibility](ide-sessions.md), including the separate limits for provider panels and remote workspaces.
