import AppKit
import SwiftUI
import XCTest
@testable import Weekleft
@testable import WeekleftCore

/// N-05 / N-09 / T-20: the editor rows in Settings → Connections with fixture endpoints.
final class IDEConnectionStatusTests: XCTestCase {
    private func endpoint(_ editor: SessionIDE, _ state: IDEBridge.Endpoint.State, companion: String? = nil) -> IDEBridge.Endpoint {
        .init(editor: editor, bundleIdentifier: editor == .vscode ? "com.microsoft.VSCode" : "com.jetbrains.pycharm",
              appPath: "/Applications/Fixture.app", companion: companion, state: state, descriptor: nil)
    }

    func testRowsDistinguishUpdateUnresponsiveIncompatibleAndMissingCompanions() {
        XCTAssertEqual(IDEConnectionsView.status(.vscode, endpoints: [endpoint(.vscode, .live, companion: "0.1.2")], bundled: "0.1.2"),
                       L("Модуль работает"))
        XCTAssertEqual(IDEConnectionsView.status(.vscode, endpoints: [endpoint(.vscode, .live)], bundled: "0.1.2"),
                       L("Установлен {0}, доступен {1}: переустановите модуль", L("0.1.1 или раньше"), "0.1.2"))
        XCTAssertEqual(IDEConnectionsView.status(.vscode, endpoints: [endpoint(.vscode, .stale, companion: "0.1.2"),
                                                                     endpoint(.vscode, .live, companion: "0.1.1")], bundled: "0.1.3"),
                       L("Установлен {0}, доступен {1}: переустановите модуль", "0.1.2", "0.1.3"))
        XCTAssertEqual(IDEConnectionsView.status(.jetbrains, endpoints: [endpoint(.jetbrains, .live)], bundled: "0.1.1"),
                       L("Модуль работает"), "The bundled JetBrains companion is not newer than an installed 0.1.1")
        XCTAssertEqual(IDEConnectionsView.status(.jetbrains, endpoints: [endpoint(.jetbrains, .unreachable)], bundled: "0.1.2"),
                       L("Модуль не отвечает: перезапустите окно редактора"))
        XCTAssertEqual(IDEConnectionsView.status(.jetbrains, endpoints: [endpoint(.jetbrains, .incompatible), endpoint(.jetbrains, .unreachable)],
                                                 bundled: "0.1.2"), L("Версия модуля не подходит: переустановите модуль"))
        XCTAssertEqual(IDEConnectionsView.status(.jetbrains, endpoints: [endpoint(.vscode, .live)], bundled: "0.1.2"), L("Модуль не подключён"))
    }

    func testBundledManifestDeclaresTheCompanionVersions() {
        let versions = IDEConnectionsView.bundledVersions()
        XCTAssertNotNil(versions[.vscode], "manifest.json must name the bundled VS Code companion")
        XCTAssertNotNil(versions[.jetbrains], "manifest.json must name the bundled JetBrains companion")
    }

    /// Opt-in visual check of the rows: LUNAVECT_RENDER_IDE_CONNECTIONS=<directory>.
    @MainActor func testRenderEditorRowsForInspection() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_IDE_CONNECTIONS"] else {
            throw XCTSkip("Set LUNAVECT_RENDER_IDE_CONNECTIONS to inspect the editor rows")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtures: [(String, [IDEBridge.Endpoint])] = [
            ("update-and-unresponsive", [endpoint(.vscode, .live), endpoint(.jetbrains, .unreachable)]),
            ("connected-and-incompatible", [endpoint(.vscode, .live, companion: "0.1.2"), endpoint(.jetbrains, .incompatible)]),
            ("missing", [])
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, endpoints) in fixtures {
                let view = VStack(alignment: .leading, spacing: 12) {
                    IDEConnectionStatusList(endpoints: endpoints, bundled: [.vscode: "0.1.2", .jetbrains: "0.1.2"], package: { _ in URL(fileURLWithPath: "/") })
                }.font(.system(size: 12)).padding(16).frame(width: 460, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(scheme)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                host.frame = CGRect(x: 0, y: 0, width: 460, height: 130)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host
                for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("\(name)-\(scheme == .light ? "light" : "dark").png"))
                window.contentView = nil
            }
        }
    }
}
