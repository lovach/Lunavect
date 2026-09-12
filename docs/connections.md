# Connecting Claude Code and Codex

Connect either provider or both in **Settings → Connections**. Lunavect checks each provider separately: finding the client, confirming sign-in, configuring local events and receiving fresh usage data are different steps.

## Requirements

- **Claude:** Claude Code CLI. Claude Desktop alone cannot supply the CLI usage integration.
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

Local catalog entries and titles are not evidence that a session is working. Fallback readers depend on client file formats, so a client update can affect detection. See [sessions](sessions.md) for state handling and navigation limits.

## Local changes

Default client configuration files are `~/.claude/settings.json` and `~/.codex/hooks.json`. Lunavect respects `CLAUDE_CONFIG_DIR` and `CODEX_HOME` when set in the app's environment. Advanced connection settings provide a manual Codex executable path when automatic discovery is insufficient.

Hooks invoke the bundled `LunavectHook` helper. It keeps session identity, project, client, state, tool name and timestamps, not the prompt or tool arguments. The Claude status-line handler stores quota values rather than the full input payload. Setup launchers contain commands and paths, not copied authentication tokens.

For all storage paths, backups, permissions and network behavior, see [Privacy and permissions](../PRIVACY.md).

## Troubleshooting

- **Client not found:** use the guide's installation action or check the executable path in advanced settings.
- **Not signed in:** complete the official client's login step, then retry its status check.
- **No session events:** check handler installation and, for Codex, handler approval. An already open client session may need to be reopened.
- **Quota unavailable:** follow the selected provider's diagnostic action. Check whether the official client itself shows that allowance. Missing values remain unavailable.
- **Offline or stale:** the last observation keeps its original timestamp. When connectivity returns, Lunavect retries; network availability alone does not prove that the provider is responding.

## Disconnect

Disconnect a provider in **Settings → Connections** before removing Lunavect. This removes its event handlers and restores the saved previous Claude status line when applicable. Unrelated client settings and handlers remain in place.

If cleanup fails, the app reports the error; resolve it before deleting the app. Disconnecting does not sign you out of the official client, delete its conversations or erase Lunavect's existing history. Removing only the app does not undo handler configuration. See [uninstalling](installation.md#uninstall).

## Interface references

- Claude Code: [setup](https://code.claude.com/docs/en/setup), [authentication](https://code.claude.com/docs/en/authentication), [status line](https://code.claude.com/docs/en/statusline), [hooks](https://code.claude.com/docs/en/hooks).
- Codex: [CLI](https://learn.chatgpt.com/docs/cli), [authentication](https://learn.chatgpt.com/docs/auth), [app-server](https://learn.chatgpt.com/docs/app-server), [hooks](https://learn.chatgpt.com/docs/hooks).

These references describe the clients' interfaces, not a certification or endorsement of Lunavect. Current installation and compatibility evidence is recorded in [verification](verification.md).
