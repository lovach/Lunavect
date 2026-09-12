# SVG icon sources

Claude and Codex SVGs are from the community-maintained LobeHub Icons collection, package @lobehub/icons-static-svg version 1.95.0, MIT licensed.

- Claude: https://github.com/lobehub/lobe-icons/blob/master/packages/static-svg/icons/claude.svg
- Codex: https://github.com/lobehub/lobe-icons/blob/master/packages/static-svg/icons/codex.svg
- License: [ThirdParty-LICENSE.txt](ThirdParty-LICENSE.txt), copied from https://github.com/lobehub/lobe-icons/blob/master/LICENSE

Original SVG geometry is unchanged. Names and marks identify their respective products in the independent Lunavect application.

## Clawd animation sources

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
- Clawd belongs to Anthropic. The archive documents provenance and does not grant a redistribution license.

The old `clawd-laptop.gif` from https://cleverhack.com/img/clawd.gif is retained only as the previously selected reference; it is no longer used by the animation renderer. Its color mask was removed because it damaged the laptop and eye details.

## Codex companion

`codex-companion.webp` is sourced from `webview/assets/codex-spritesheet-v6-51045ae208c0.webp` in ChatGPT.app's `app.asar`. The built-in catalog labels it "The original Codex companion." Native rendering uses the typing scene at row 7, columns 0–5, cells 192 × 208, with source durations 120/120/120/120/120/220 ms. Original alpha and colors are preserved.

Importing the asset does not establish redistribution permission.

## Permission status

Permission to redistribute these exact Clawd and Codex companion animation assets has not been established. Their inclusion does not grant downstream redistribution rights. The root MIT license covers Lunavect's original code, not these assets or the providers' marks. See [NOTICE](../../../NOTICE).
