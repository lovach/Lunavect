import Foundation
import XCTest
@testable import Weekleft

final class LegacyRenderIsolationTests: XCTestCase {
    @MainActor func testPreviewCompositionInsideProvenSandbox() throws {
        try LegacyRenderIsolation.require()
        let preview = try LegacyRenderFixture()
        defer { preview.stop() }
        XCTAssertTrue(preview.environment.isPreview)
        XCTAssertFalse(preview.environment.defaults === UserDefaults.standard)
        XCTAssertEqual(preview.environment.defaults.string(forKey: "languageCode"), try LegacyRenderIsolation.language())
        XCTAssertEqual(preview.environment.sessions.sessions, preview.presentation.sessions())
        XCTAssertEqual(preview.environment.store.snapshots, preview.presentation.snapshots)
    }

    func testOrdinaryOptInIsInsufficientToEvaluateLegacyViews() {
        XCTAssertThrowsError(try LegacyRenderIsolation.language(environment: ["LUNAVECT_RENDER_SETTINGS": "/tmp/output"]))
    }

    func testReadableSentinelCannotMasqueradeAsSandboxProof() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("synthetic canary".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try LegacyRenderIsolation.language(environment: [
            "LUNAVECT_NATIVE_RENDER_ISOLATION": "passed", "LUNAVECT_PREVIEW_LANGUAGE": "ru",
            "LUNAVECT_NATIVE_RENDER_FORBIDDEN": file.path]))
        XCTAssertEqual(try Data(contentsOf: file), Data("synthetic canary".utf8))
    }
}
