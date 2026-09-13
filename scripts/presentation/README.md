# Public interface media

`DemoMain.swift` is a media-only app entry point. It uses Lunavect's native SwiftUI views and AppKit status item with fictional sessions, allowances and activity. It does not connect providers or read the user's sessions.

The public 18-second demo illustrates working → permission needed → response ready. Its side-by-side widget views are **previews**, not WidgetKit widgets placed on a desktop. It does not demonstrate a click returning to an external client.

Prepare a new source copy without changing the live application entry point:

```sh
python3 scripts/presentation/prepare.py --output /path/to/new-media-source
cd /path/to/new-media-source
swift build --jobs 2
```

The preparer retains shared popover support from `Main.swift`, removes only the production launcher's `@main` attribute in the copy, and adds `DemoMain.swift` plus the shared fictional `PresentationFixture`. Replacing the whole `Main.swift` would remove types needed by other native controls. Use a new output directory; the tool never overwrites an existing one. Do not install the media app or give it the installed application's bundle ID.

`DemoState` uses `AppEnvironment.preview` for private defaults, in-memory data and injected inactive services. Both session views receive that preview's explicit updates and awake dependencies. The status-item preview uses the native value view directly, so it does not construct the live `MenuBarAnimator` update observer. Termination stops the preview and removes its temporary state.

The separate media application is still a whole-window exporter and is **not allowlisted** by the strict native render launcher. Build/typecheck is safe to run; do not run `LUNAVECT_DEMO_OUTPUT` or whole-window XCTest exporters outside the reviewed isolation workflow. The routine allowed checks are documented in [development](../../docs/development.md#isolated-native-render-checks). Media compilation does not establish rendering or desktop WidgetKit behavior.

When this broader exporter has an approved sandbox path, its intended output is 180 native window frames at 10 fps, with working, permission and ready stages. Inspect the beginning, permission state and end before encoding or publishing. Keep the media source/fixture revision together with the reviewed images; never substitute private histories.

## README gallery

The `readme-*.png` exports use the same native components and fictional fixture. Overview and session panels have separate light and dark exports. Their outer canvas is transparent so the page background shows through; the application and widget surfaces retain their native appearance. The renderer requires at least two native pixels per layout point for these transparent exports and does not upscale them.

The README displays the overview at 784 points and individual panels at 392 points. On narrow screens the overview uses a single session panel, and the light/dark panels wrap onto separate rows. The full activity window is captured at 920 × 1060 points so the project breakdown is visible. Keep all gallery exports from one renderer run so their activity totals agree.

## Retouched desktop capture

`docs/images/macos-menu-bar.png` is based on the owner's macOS screenshot of a local development build. The built-in image editing tool removed the Comfy Desktop shortcut and a stray desktop icon fragment, substituted English sample session titles, project paths and quota values, and balanced the framing. This is a retouched capture, not an untouched screenshot or a new native-render validation. The original private capture is not included in Git.

The menu-bar usage indicators shown in this image are a development preview and are not included in the 0.1.0 installer. The other README close-ups remain native renders with fictional data.
