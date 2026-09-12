import SwiftUI
import WidgetKit
#if SWIFT_PACKAGE
import WeekleftCore
#endif

@MainActor final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    @Published var code: String {
        didSet {
            L10n.defaults.set(code, forKey: "languageCode")
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    private init() { code = L10n.selection }
}
struct LocalizedRoot<Content: View>: View {
    @ObservedObject private var language = LanguageSettings.shared
    @AppStorage("interfaceAppearance") private var appearance = InterfaceAppearance.dark
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().environment(\.locale, Locale(identifier: AppLanguage.resolve(language.code))).id(language.code)
            .preferredColorScheme(appearance.scheme)
            .background(InterfaceWindowAppearance(appearance: appearance))
    }
}

enum InterfaceAppearance: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String { L(self == .system ? "Как в системе" : self == .dark ? "Тёмная" : "Светлая") }
    var scheme: ColorScheme? { self == .system ? nil : self == .dark ? .dark : .light }
    var native: NSAppearance? { self == .system ? nil : NSAppearance(named: self == .dark ? .darkAqua : .aqua) }
}
private struct InterfaceWindowAppearance: NSViewRepresentable {
    var appearance: InterfaceAppearance
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) { view.mode = appearance; view.window?.appearance = appearance.native }
    class Surface: NSView {
        var mode = InterfaceAppearance.dark
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.appearance = mode.native }
    }
}
struct LanguagePicker: View {
    @ObservedObject private var language = LanguageSettings.shared
    var body: some View {
        HStack {
            InterfaceLabel(L("Язык"), .globe)
            Spacer()
            Picker(L("Язык"), selection: $language.code) {
                ForEach(AppLanguage.allCases) { item in Text(item.title).tag(item.rawValue) }
            }.labelsHidden().frame(width: 190).accessibilityIdentifier("app-language")
        }
    }
}
