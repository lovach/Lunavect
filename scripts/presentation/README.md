# Public interface media

`DemoMain.swift` is a media-only app entry point. It uses Lunavect's native SwiftUI views and AppKit status item with fictional sessions, allowances and activity. It does not connect providers or read the user's sessions.

The public 18-second demo illustrates working → permission needed → response ready. Its side-by-side widget views are **previews**, not WidgetKit widgets placed on a desktop. It does not demonstrate a click returning to an external client.

Build it in a separate temporary source copy, replacing that copy's `Sources/Weekleft/Main.swift` with `DemoMain.swift`. Also copy `Tests/WeekleftUITests/PresentationFixture.swift` into that copy’s `Sources/Weekleft/` directory. Both the still renderer and video use this shared fictional dataset. Do not replace the entry point in your working app, use the installed app's bundle ID, or install this media app.

Run the resulting executable with `LUNAVECT_PREVIEW_LANGUAGE=en` and `LUNAVECT_DEMO_OUTPUT` pointing to an empty temporary directory. It records 180 native window frames at 10 frames per second and exits. Encode with a local video tool as H.264, 10 fps, yuv420p, fast-start MP4. Build the recording from the same source revision and fixture as the public stills, separate from ongoing application changes.

For the still images, keep the normal app entry point and run:

```sh
LUNAVECT_RELEASE_SCREENSHOTS="$PWD/docs/images" swift test --filter ReleaseScreenshots.testRenderPublicScreenshots
```

Inspect the exported images and the beginning, permission state and end of the video before publishing. Never replace fictional fixtures with local session history. The renderer is an opt-in asset tool, not an end-to-end provider or WidgetKit test.

## README gallery

The `readme-*.png` exports use the same native components and fictional fixture. Overview and session panels have separate light and dark exports. Their outer canvas is transparent so the page background shows through; the application and widget surfaces retain their native appearance. The renderer requires at least two native pixels per layout point for these transparent exports and does not upscale them.

The README displays the overview at 784 points and individual panels at 392 points. On narrow screens the overview uses a single session panel, and the light/dark panels wrap onto separate rows. The full activity window is captured at 920 × 1060 points so the project breakdown is visible. Keep all gallery exports from one renderer run so their activity totals agree.

## Retouched desktop capture

`docs/images/macos-menu-bar.png` is based on the owner's macOS screenshot of a local development build. The built-in image editing tool removed the Comfy Desktop shortcut and a stray desktop icon fragment, substituted English sample session titles, project paths and quota values, and balanced the framing. This is a retouched capture, not an untouched screenshot or a new native-render validation. The original private capture is not included in Git.

The menu-bar usage indicators shown in this image are a development preview and are not included in the 0.1.0 installer. The other README close-ups remain native renders with fictional data.
