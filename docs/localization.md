# Interface languages

Lunavect supports English, Russian, German, Spanish, French and Simplified Chinese. On first use it selects the first supported language in the system preferences, falling back to English. Chinese system variants currently select Simplified Chinese; there is no separate Traditional Chinese translation.

Choose a language in **Settings → General**. The app updates without a restart and requests a WidgetKit refresh. macOS decides when the placed widget redraws. Client-supplied session titles and project names remain unchanged. Missing-title placeholders are generated for display in the selected language; standard macOS dialogs may follow the system language.

## Contributing a translation

The app and widget share [Translations.json](https://github.com/lovach/Lunavect/blob/main/Sources/WeekleftCore/Resources/Translations.json). Russian source strings are stable lookup keys. Each translated entry has `en`, `de`, `es`, `fr` and `zh-Hans` values.

Preserve placeholders such as `{0}` and `{1}`. Keep Lunavect, Claude, Claude Code, Codex, tool names and commands such as `/hooks` unchanged. German and French use polite forms of address; Spanish uses a consistent tú form. Prefer short status labels that fit both compact session rows and widgets.

Durations use the same abbreviated units across activity and quotas and omit a zero lower component (for example, `3 d` or `8 hr`). German distinguishes the ongoing-session filter (`Laufend`), working status (`Arbeitet`) and running count (`in Arbeit`). The feature name **Keep Awake** is consistent across its settings and panel controls.

Dates use the selected language with the region, 12- or 24-hour clock and first weekday from macOS, so an English interface in Austria shows 14:30 and weeks starting on Monday. Manually entered subscription dates and user content must not be translated into different values. Decorative [thinking phrases](thinking-phrases.md) remain English in every interface language.

## Verification

```sh
swift test --jobs 2 --filter LocalizationTests
```

The suite checks language coverage, placeholder consistency, locale selection, shared duration units and direct literal lookup keys in the Swift source. It does not treat a key absent from a literal search as unused: enum-selected labels, computed keys and persisted diagnostics require manual tracing before removal. Also inspect affected native views for truncation and incorrect terminology.

The isolated native smoke matrix renders synthetic limits and activity in Russian
and German, in both color schemes:

```sh
python3 scripts/check-native-renders.py --run --require-render --output build/native-renders
```

Inspect its gallery and result report. Use `--suite legacy-values` for the additional RU/DE import reports, freshness cards, contour and glyph exports. The launcher passes a process-only Debug language and never writes `L10n.defaults`. Other languages and complete settings/session flows still need focused visual checks.

The updated `--render-native OUTPUT.png` entry point is Debug-only and renders synthetic unknown allowances. Preview arguments are parsed before live services or defaults are initialized; Release builds reject these preview flags. `--session-preview FIXTURE.json` similarly requires Debug and composes the session UI with the isolated preview environment. These source paths do not read the user's saved allowances. The CLI entry point and the sandboxed XCTest matrix remain separate verification scopes: passing the latter alone does not prove execution of the final app binary's CLI. Neither verifies a widget placed on the desktop. See [check boundaries](checks-and-release-gates.md).

[Contributing](https://github.com/lovach/Lunavect/blob/main/.github/CONTRIBUTING.md) · [Development](development.md)
