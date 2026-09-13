# Public screenshots

The README gallery shows the production interface from Lunavect 0.1.1, captured on September 13, 2026. All session titles, paths, quotas and activity are fictional. The eleven images were generated together and visually inspected at their native resolution.

## Rebuild the gallery

From a fixed source checkout, use a new output directory:

```sh
python3 scripts/check-native-renders.py --run --require-render \
  --suite public-gallery --output build/public-gallery
```

The launcher runs `ReleaseScreenshots.testRenderPublicScreenshots` inside the same deny-default sandbox as the other native checks. Its preflight verifies denied access to shared preferences, unrelated files, child processes and the network. The exporter uses `AppEnvironment.preview`, private defaults, temporary files and inactive injected services. It neither opens visible windows nor installs an app.

SwiftUI and AppKit controls render into an offscreen native window at two pixels per layout point. Images are not enlarged after rendering. Widgets use the production card views; the menu-bar comparison uses the production indicator previews. This does not exercise desktop WidgetKit placement, glass compositing or external clients.

One capture-time fixture keeps the sessions fresh and the displayed totals consistent. Timestamps and calendar labels can change between runs, so a changed PNG hash is not by itself a visual regression. The renderer records image hashes, dimensions, accessibility values and source provenance beside `gallery.html`. Keep those reports with the reviewed run; do not publish raw logs or private histories.

| Images | Layout size in points |
| --- | --- |
| Overview, light and dark | 784 × 403 |
| Sessions, light and dark | 392 × 387 |
| Limits settings | 920 × 640 |
| Activity statistics | 920 × 980 |
| Menu-bar styles | 720 × 144 |
| Overview and large activity widgets | 344 × 344 |
| Small activity widget | 164 × 164 |
| Limits widget | 344 × 164 |

Inspect every image for clipped text, missing controls, inconsistent totals and unintended private data before copying the eleven PNGs into `docs/images`. The README switches its hero between light/dark appearances and uses a single session panel on narrow screens.

The installer image documents the unchanged branded Finder layout; its historical inspection is recorded separately in [verification](verification.md). Obsolete galleries, the retouched desktop image and the unused demo movie have been removed.
