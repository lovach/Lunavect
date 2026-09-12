import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

/// macOS owns widget placement. This guide never requests control of other applications.
@MainActor struct WidgetGalleryControls: View {
    var selection: String = ""
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Добавление виджета")).font(.headline)
            if !selection.isEmpty {
                Text(selection).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            step("1", "Правый клик по рабочему столу → «Изменить виджеты»")
            HStack(alignment: .top) {
                step("2", "Найдите Lunavect в галерее")
                Spacer(minLength: 8)
                Button(L(copied ? "Скопировано" : "Скопировать название")) {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString("Lunavect", forType: .string)
                }.buttonStyle(.borderless).font(.system(size: 12))
                    .accessibilityIdentifier("copy-widget-name")
            }
            step("3", "Нажмите нужный виджет — macOS разместит его")
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("widget-placement-guide")
    }
    private func step(_ number: String, _ title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 18)
            Text(L(title)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
