# Lunavect Sessions

Install this companion from the VSIX included with Lunavect: **Settings → Connections → Sessions in editors → Show module**, then **Extensions → … → Install from VSIX** in VS Code or Cursor. Open a local project and refresh the connection in Lunavect. Enable Claude/Codex local events in Lunavect and restart sessions that were already running when you installed the integration.

The extension selects the existing integrated terminal by its process ID. For the official Claude Code and Codex extensions it opens the requested conversation in the matching workspace. It does not send terminal input, read terminal output, request credentials, or call model APIs. It uses a private local Unix socket in your user temporary folder and a fresh VS Code callback to select the right window. If macOS cleans that folder, the socket is recreated within 30 seconds. If the connection cannot start, VS Code shows a warning.

Supported: local macOS VS Code, VS Code Insiders, Cursor and other editors built on VS Code; the extension reports the editor's own bundle identifier from its `product.json`, and Lunavect checks it against the running app. Remote SSH, containers and WSL are not supported; Lunavect says so instead of guessing a window. If several windows match the same provider conversation, close the duplicate workspace before trying again. A stopped terminal session is not automatically resumed.

The extension reports its version to Lunavect, which suggests reinstalling when the app bundles a newer one. Uninstall through VS Code's Extensions view. Closing the editor removes its connection; a forced quit leaves a stale descriptor that Lunavect ignores and removes after a day.
