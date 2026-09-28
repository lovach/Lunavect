# Sessions in VS Code and JetBrains

The IDE companions let Lunavect select the **existing terminal tab** where Claude Code or Codex is running. Clicking a live session does not run a resume command or start another agent.

| Session location | Navigation |
| --- | --- |
| VS Code / VS Code Insiders, local integrated terminal | Selects the terminal by its live process ancestry, then confirms window and terminal focus |
| JetBrains 2026.2 IDEs, Terminal tool window | Selects the exact Reworked or Classic terminal and its project window. Every `com.jetbrains.<product>` IDE and its EAP build is recognized; IntelliJ IDEA is the exercised product |
| Official Claude Code extension in local VS Code | Opens the session ID through the provider extension in the matching workspace |
| Official Codex extension in local VS Code | Opens the session's custom editor, reusing its existing editor group |
| JetBrains AI Chat / Claude Agent / Codex Agent panels | Not supported by this companion |
| Other JetBrains versions, remote SSH, containers, WSL, VS Code forks (Cursor, Windsurf, VSCodium) | Not supported by this version; forks are reported by name |

The JetBrains terminal companion supports both providers in the **Terminal tool window**. It matches a tab by the process the tab started, so a Reworked tab whose Claude process has no controlling terminal is still found. Claude Code installed with npm (`npm i -g @anthropic-ai/claude-code`) is recognized like the native installer: current releases run the package's `bin/claude.exe`, earlier ones `node …/@anthropic-ai/claude-code/cli.js`. Separate chat panels, including terminals owned by other plugins outside that tool window, need their own navigation integration. JetBrains' built-in Codex integration also uses a separate session home; this feature does not import that account or configure its hooks.

## Setup

1. In Lunavect, enable the provider's local events under **Settings → Connections**.
2. Expand **Sessions in editors**, then select **Show installer** beside your editor.
3. In VS Code, use **Extensions → … → Install from VSIX** and select `lunavect-vscode.vsix`. In JetBrains 2026.2, use **Settings → Plugins → ⚙ → Install Plugin from Disk** and select `lunavect-jetbrains.zip`.
4. Reload/restart the editor if it asks. Open your local project, return to Lunavect and choose **Refresh connection**. The status should say **Companion connected**.
5. Restart sessions which were already running before you enabled local events, so their next events carry the editor identity.

Lunavect 0.2.6 bundles VS Code companion **0.1.2** and JetBrains companion **0.1.2** (0.2.5 bundled JetBrains 0.1.1). Replacing the app does not replace editor plugins: repeat step 3 with the new installer and reload/restart the editor.

From 0.1.2 each companion reports its version. **Settings → Connections → Sessions in editors** then shows “Installed X, available Y: reinstall the companion” when the app bundles a newer one; 0.1.0 and 0.1.1 report no version and appear as “0.1.1 or earlier”. The same rows distinguish a companion that is installed but not answering and one whose descriptor protocol does not match this app.

The installers are included in the app. No Marketplace login, provider login, Accessibility permission or terminal input is needed for the companion. Provider sign-in and model usage remain in the provider's own application.

If multiple windows contain the same provider workspace, Lunavect reports the ambiguity rather than choosing an arbitrary window. Keep that project in one window and retry. A closed terminal, exited process, missing companion, companion that is installed but not answering, incompatible companion, busy editor (for example indexing; probes wait up to five seconds) and a window macOS refuses to bring forward each produce an editor-specific message naming the product, such as PyCharm. The app does not fall back to Apple Terminal or Codex Desktop for an identified IDE session.

## Privacy and lifecycle

The app records the provider runtime's PID and birth time and checks them again at click time. It reads executable paths and parent PIDs, not foreign environment variables. Arguments are read only for your own `node`/`bun` processes, to recognize a Claude Code installed with npm by its package script, and for a listed Claude runtime, to recognize the exact command line of Lunavect's limits check; they are compared and not kept. The kernel returns the process's environment after its arguments in the same block; it is discarded unparsed. The companion uses the editor's terminal process API; it never reads terminal text or injects keystrokes.

Local descriptors live in `~/Library/Application Support/Lunavect/IDEBridge`. User-only Unix sockets live in a `lunavect` folder inside the temporary folder the editor was started with (`$TMPDIR/lunavect`, also when a shell profile, `nix develop` or devbox sets another `TMPDIR`, or `/tmp/lunavect` when it is unset); companions 0.1.0 and 0.1.1 use `/tmp/lunavect-ide-<uid>`, which the app still accepts. Lunavect connects only if that folder is a real directory owned by you without group or other access (not a link), and only to a socket whose peer runs as you. If the temporary folder is cleaned while the editor runs, the companion recreates its socket within 30 seconds, and a descriptor whose heartbeat is late after sleep is still tried. If a companion cannot start (for example, its folder is a link or belongs to another user), the editor shows a warning. Protocol messages contain only navigation metadata: process IDs, session ID and working directory. They carry no prompts, transcript content, keys or tokens. Probes do not focus windows. Opening requires a unique match and a fresh acknowledgement. VS Code callbacks are single use and routed to the companion window.

Uninstall the companion through your editor's plugin manager. On normal shutdown it removes its descriptor and socket; the app ignores stale records after a forced exit and removes them after a day. It removes only files in its own descriptor format, never records of a running editor.

## Development and verification

Source lives in `integrations/vscode` and `integrations/jetbrains`. The JetBrains plugin deliberately declares compatibility only with build `262.*`, matching the SDK used for compilation. Its Reworked-terminal calls use `@ApiStatus.Experimental` terminal APIs: in 2025.3 (`253`) `TerminalStartupOptions` has no process ID, so that version cannot match Reworked tabs; 2026.1 (`261`) and 2026.3 (`263`) need their own SDK compile, the JetBrains Plugin Verifier and a live Classic/Reworked check before the range is widened. Rebuild the bundled installers after any companion source change:

```sh
python3 scripts/package-ide-connectors.py --jetbrains-sdk '/path/to/IntelliJ IDEA.app'
node --test integrations/vscode/protocol.test.js integrations/vscode/routing.test.js
./scripts/check.sh
```

The packager requires IntelliJ IDEA 2026.2 with its bundled `javac`; it does not download dependencies or install plugins. The package manifest records the hashes of the files packaged into each installer (tests and notes are not included, so editing them needs no rebuild), the artifact hashes and the bundled companion versions. The normal checks reject stale installers and verify the actual app's bundled files.

Without the SDK, `python3 scripts/package-ide-connectors.py --vscode-only` rebuilds only the VS Code installer and keeps the bundled JetBrains one. JetBrains sources changed since that build are then listed in the manifest's `pendingSources` with their current hashes; the checks accept this only for JetBrains sources and only while those hashes are current. A release must be built after a full `--jetbrains-sdk` run, which clears `pendingSources`.

Opt-in native checks (skipped by default; they focus only operator-owned fixture windows). Every other test that reaches navigation's default system steps (Terminal or iTerm2 scripting, the companion bridge, Claude Desktop records, Claude or Codex links) fails with `SessionNavigation.LiveSystemRefused` instead of touching your applications; only these tests opt in:

| Variable | Test | What it checks |
| --- | --- | --- |
| `LUNAVECT_IDE_NAVIGATION_FIXTURE` | `testExplicitIDEFixtureFromProcessOriginThroughNativeFocus` | IDE terminal fixtures through the real companion |
| `LUNAVECT_TERMINAL_NAVIGATION_FIXTURE` | `testExplicitDetachedHookAndCatalogOpenRealTerminal` | Apple Terminal tab by device; with `windowID` the restored live window; with `"otherSpace": true` a window moved to another Space or full screen is on screen afterwards |
| `LUNAVECT_ITERM_NAVIGATION_FIXTURE` | `testExplicitITermFixtureSelectsTheSessionAndRestoresItsWindow` | iTerm2 window, tab and pane of `{"clientPID", "tty"}`, including a minimized window |
| `LUNAVECT_RENDER_IDE_CONNECTIONS` | `testRenderEditorRowsForInspection` | Renders the editor rows in Settings for visual inspection |

`SessionNavigationIntegrationTests.testExplicitIDEFixtureFromProcessOriginThroughNativeFocus` is an opt-in native test. Set `LUNAVECT_IDE_NAVIGATION_FIXTURE` to a JSON file describing operator-owned dummy processes (`terminals`, optional `providers`, and `cwd`). It inspects their actual origins and calls the real app navigation. It must never target an unrelated user session.

The September 26 implementation was exercised in real local VS Code and IntelliJ IDEA 2026.2.3 with inert Claude/Codex-named fixture processes, including Classic and Reworked terminals. These tests make no model requests. The provider-panel routes have contract tests against the inspected official extension interfaces (VS Code reports an extension's webview panel tab with the workbench's `mainThreadWebview-` prefix, which the Claude panel check accepts); authenticated, end-to-end provider-panel behavior is **not yet verified**. Linux/Windows, remote editors, older JetBrains builds and other JetBrains products were not exercised.

Reference interfaces: [VS Code extension API](https://code.visualstudio.com/api/references/vscode-api), [JetBrains embedded terminal API](https://plugins.jetbrains.com/docs/intellij/embedded-terminal.html), [JetBrains Codex integration and separate home](https://youtrack.jetbrains.com/projects/AI4SE/articles/SUPPORT-A-3134/How-does-Codex-CLI-integration-Codex-Agent-work-in-JetBrains-IDEs).
