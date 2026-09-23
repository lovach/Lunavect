# Security

## Report a vulnerability

Use [Report a vulnerability](https://github.com/lovach/Lunavect/security/advisories/new) to send a private report to the repository maintainer. A GitHub account is required. Do not put exploit details or private data in a public issue.

Include:

- The Lunavect version and build, macOS version and Mac architecture.
- The affected component and the access an attacker would need.
- Reproduction steps using a test account or fictional data, and the expected impact.
- A minimal example or suggested fix, if available.

Remove passwords, tokens, personal conversations and signing keys from attachments. If reproduction needs sensitive material, describe what is needed before sharing it.

## Versions and scope

Check the [latest public release](https://github.com/lovach/Lunavect/releases/latest) before reporting and say whether the problem also occurs there. If you cannot test that version, include the version you used. Fixes are distributed through new releases; old release files are not silently replaced with a patched app.

Relevant areas include local event handlers, configuration changes, session and activity storage, client launchers, the optional keep-awake helper and update installation. For vulnerabilities in Claude Code, Codex or another dependency, identify the upstream component so the report can be directed appropriately.

For installation problems, incorrect values and feature requests without a security impact, use [Issues](https://github.com/lovach/Lunavect/issues/new/choose). See [Privacy and permissions](../docs/privacy.md) for the data Lunavect uses.
