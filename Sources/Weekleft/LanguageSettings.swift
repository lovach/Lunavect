import SwiftUI
import WidgetKit
#if SWIFT_PACKAGE
import WeekleftCore
#endif

@MainActor final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    private let defaults: UserDefaults
    private let reloadWidgets: () -> Void
    @Published var code: String {
        didSet {
            guard code != oldValue else { return }
            defaults.set(code, forKey: "languageCode")
            reloadWidgets()
        }
    }
    init(defaults: UserDefaults? = nil, reloadWidgets: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        self.defaults = defaults ?? L10n.defaults
        self.reloadWidgets = reloadWidgets
        code = defaults.map { $0.string(forKey: "languageCode") ?? "system" } ?? L10n.selection
    }
}
struct LocalizedRoot<Content: View>: View {
    @ObservedObject var language: LanguageSettings
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
    @ObservedObject var language: LanguageSettings
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
