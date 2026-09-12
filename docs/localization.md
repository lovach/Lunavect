# Interface languages

Lunavect supports English, Russian, German, Spanish, French and Simplified Chinese. On first use it selects the first supported language in the system preferences, falling back to English. Chinese system variants currently select Simplified Chinese; there is no separate Traditional Chinese translation.

Choose a language in **Settings → General**. The app updates without a restart and requests a WidgetKit refresh. macOS decides when the placed widget redraws. Session titles and project names remain as supplied by the clients; standard macOS dialogs may follow the system language.

## Contributing a translation

The app and widget share [Translations.json](../Sources/WeekleftCore/Resources/Translations.json). Russian source strings are stable lookup keys. Each translated entry has `en`, `de`, `es`, `fr` and `zh-Hans` values.

Preserve placeholders such as `{0}` and `{1}`. Keep Lunavect, Claude, Claude Code, Codex, tool names and commands such as `/hooks` unchanged. German and French use polite forms of address; Spanish uses a consistent tú form. Prefer short status labels that fit both compact session rows and widgets.

Dates use the selected locale. Manually entered subscription dates and user content must not be translated into different values. Decorative [thinking phrases](thinking-phrases.md) remain English in every interface language.

## Verification

```sh
swift test --filter LocalizationTests
```

The suite checks language coverage, placeholder consistency and locale selection. Also inspect affected native views for truncation and incorrect terminology.

A Debug build can render a widget preview without changing the saved language:

```sh
LUNAVECT_PREVIEW_LANGUAGE=fr /path/to/Lunavect.app/Contents/MacOS/Lunavect --render-native /tmp/lunavect-widget-fr.png
```

Replace the app path with your Debug build. This renders native widget content; it does not verify a widget placed on the desktop or change macOS language settings.

[Contributing](../CONTRIBUTING.md) · [Development](development.md)
