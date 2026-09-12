# SVG icon sources

Claude and Codex SVGs are from the community-maintained LobeHub Icons collection, package @lobehub/icons-static-svg version 1.95.0, MIT licensed.

- Claude: https://github.com/lobehub/lobe-icons/blob/master/packages/static-svg/icons/claude.svg
- Codex: https://github.com/lobehub/lobe-icons/blob/master/packages/static-svg/icons/codex.svg
- License: [ThirdParty-LICENSE.txt](ThirdParty-LICENSE.txt), copied from https://github.com/lobehub/lobe-icons/blob/master/LICENSE

Original SVG geometry is unchanged. The preview adds class and accessibility attributes to inline copies and inherits the provider's accent color. Names and marks identify their respective products; this is an independent design prototype.

## Clawd animation sources (local evaluation)

The selected laptop reference is now rendered from vector source, avoiding destructive background/color masks. Walking and waving use transparent GIF sources; only normal proportional display scaling is applied.

Archive: https://github.com/HermannBjorgvin/Clawdmeter/tree/8290f70a8c41b049dc9171e96fb29fada2196a37/research/clawd-official

- `clawd-laptop.json`: archived `Clawd-Laptop.lottie.json`, Lottie 5.7.4, 43 frames at 12 fps. Native playback supports this source's static closed paths, identity transforms and hold opacity keys. All source paths/colors are retained.
- `clawd-walking.gif`: archived `Clawd-CrabWalking.gif`, 20 transparent frames at 80 ms.
- `clawd-waving.gif`: archived `Clawd-Waving.gif`, 17 transparent frames at 80 ms.
- The archive identifies the sources as Anthropic assets and records these upstream URLs:
  - https://assets-proxy.anthropic.com/claude-ai/v2/assets/v1/c838f53ee-DqwARLA7.json
  - https://claude.ai/images/clawd/core/Clawd-CrabWalking.gif
  - https://claude.ai/images/clawd/core/Clawd-Waving.gif
- Direct upstream retrieval returned HTTP 403 in this environment on 2026-09-10; assets were obtained from the pinned public archive, not through authenticated access or a bypass.
- Clawd belongs to Anthropic. The archive is provenance evidence, not a redistribution license. Resolve asset redistribution permission before a public release.

The old `clawd-laptop.gif` from https://cleverhack.com/img/clawd.gif is retained only as the previously selected reference; it is no longer used by the animation renderer. Its color mask was removed because it damaged the laptop and eye details.

## Codex companion (local evaluation)

User selected only the typing scene on 2026-09-10. `codex-companion.webp` is a byte-identical copy of `webview/assets/codex-spritesheet-v6-51045ae208c0.webp` in the user's installed ChatGPT.app `app.asar`. The app's built-in catalog labels it "The original Codex companion." Native rendering uses row 7, columns 0–5, cells 192 × 208, with the source durations 120/120/120/120/120/220 ms. Other actions are not played. Original alpha and colors are preserved.

This local asset import does not establish redistribution permission. Resolve permission before including proprietary companion assets in a public release.

## Permission review — 2026-09-10

The owner wants to retain both mascots for the free app. Current files remain unchanged. Official Anthropic trademark guidelines and OpenAI design guidelines were checked; no permission for redistribution of these exact animation assets was established. Findings and request drafts (the owner reported sending them): [mascot-permissions.md](../../../docs/mascot-permissions.md).
