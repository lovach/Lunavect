# Sessions in VS Code and JetBrains

The IDE companions let Lunavect select the **existing terminal tab** where Claude Code or Codex is running. Clicking a live session does not run a resume command or start another agent.

| Session location | Navigation |
| --- | --- |
| VS Code / VS Code Insiders, local integrated terminal | Selects the terminal by its live process ancestry, then confirms window and terminal focus |
| JetBrains 2026.2, Terminal tool window | Selects the exact Reworked or Classic terminal and its project window |
| Official Claude Code extension in local VS Code | Opens the session ID through the provider extension in the matching workspace |
| Official Codex extension in local VS Code | Opens the session's custom editor, reusing its existing editor group |
| JetBrains AI Chat / Claude Agent / Codex Agent panels | Not supported by this companion |
| Other JetBrains versions, remote SSH, containers, WSL, other VS Code forks | Not supported by this version |

The JetBrains terminal companion supports both providers in the **Terminal tool window**. Separate chat panels, including terminals owned by other plugins outside that tool window, need their own navigation integration. JetBrains' built-in Codex integration also uses a separate session home; this feature does not import that account or configure its hooks.

## Setup

1. In Lunavect, enable the provider's local events under **Settings → Connections**.
2. Expand **Sessions in editors**, then select **Show installer** beside your editor.
3. In VS Code, use **Extensions → … → Install from VSIX** and select `lunavect-vscode.vsix`. In JetBrains 2026.2, use **Settings → Plugins → ⚙ → Install Plugin from Disk** and select `lunavect-jetbrains.zip`.
4. Reload/restart the editor if it asks. Open your local project, return to Lunavect and choose **Refresh connection**. The status should say **Companion connected**.
5. Restart sessions which were already running before you enabled local events, so their next events carry the editor identity.

Lunavect 0.2.4 bundles companion version **0.1.1** for both editors. If you installed 0.1.0 previously, repeat step 3 with the new installer and reload/restart the editor; replacing the app does not automatically replace editor plugins.

The installers are included in the app. No Marketplace login, provider login, Accessibility permission or terminal input is needed for the companion. Provider sign-in and model usage remain in the provider's own application.

If multiple windows contain the same provider workspace, Lunavect reports the ambiguity rather than choosing an arbitrary window. Keep that project in one window and retry. A closed terminal, exited process or missing companion produces an editor-specific message. The app does not fall back to Apple Terminal or Codex Desktop for an identified IDE session.

## Privacy and lifecycle

The app records the provider runtime's PID and birth time and checks them again at click time. It reads executable paths and parent PIDs, not process arguments or foreign environment variables. The companion uses the editor's terminal process API; it never reads terminal text or injects keystrokes.

Local descriptors live in `~/Library/Application Support/Lunavect/IDEBridge`. User-only Unix sockets live under `/tmp/lunavect-ide-<uid>`. Protocol messages contain only navigation metadata: process IDs, session ID and working directory. They carry no prompts, transcript content, keys or tokens. Probes do not focus windows. Opening requires a unique match and a fresh acknowledgement. VS Code callbacks are single use and routed to the companion window.

Uninstall the companion through your editor's plugin manager. On normal shutdown it removes its descriptor and socket; the app ignores stale records after a forced exit.

## Development and verification

Source lives in `integrations/vscode` and `integrations/jetbrains`. The JetBrains plugin deliberately declares compatibility only with build `262.*`, matching the SDK used for compilation. Rebuild the bundled installers after any companion source change:

```sh
python3 scripts/package-ide-connectors.py --jetbrains-sdk '/path/to/IntelliJ IDEA.app'
node --test integrations/vscode/protocol.test.js integrations/vscode/routing.test.js
./scripts/check.sh
```

The packager requires IntelliJ IDEA 2026.2 with its bundled `javac`; it does not download dependencies or install plugins. The package manifest records source and artifact hashes. The normal checks reject stale installers and verify the actual app's bundled files.

`SessionNavigationIntegrationTests.testExplicitIDEFixtureFromProcessOriginThroughNativeFocus` is an opt-in native test. Set `LUNAVECT_IDE_NAVIGATION_FIXTURE` to a JSON file describing operator-owned dummy processes (`terminals`, optional `providers`, and `cwd`). It inspects their actual origins and calls the real app navigation. It must never target an unrelated user session.

The September 26 implementation was exercised in real local VS Code and IntelliJ IDEA 2026.2.3 with inert Claude/Codex-named fixture processes, including Classic and Reworked terminals. These tests make no model requests. The provider-panel routes have contract tests against the inspected official extension interfaces; authenticated, end-to-end provider-panel behavior is **not yet verified**. Linux/Windows, remote editors, older JetBrains builds and other JetBrains products were not exercised.

Reference interfaces: [VS Code extension API](https://code.visualstudio.com/api/references/vscode-api), [Claude Code's VS Code navigation](https://code.claude.com/docs/en/vs-code#launch-a-vs-code-tab-from-other-tools), [JetBrains embedded terminal API](https://plugins.jetbrains.com/docs/intellij/embedded-terminal.html), [JetBrains Codex integration and separate home](https://youtrack.jetbrains.com/projects/AI4SE/articles/SUPPORT-A-3134/How-does-Codex-CLI-integration-Codex-Agent-work-in-JetBrains-IDEs).
