import XCTest
import SwiftUI
@testable import Weekleft

final class SessionGeometryTests: XCTestCase {
    func testEmptySiblingCannotEraseMeasuredScrollViewport() {
        let measured = CGRect(x: 0, y: 139, width: 360, height: 300)
        var value = SessionScrollRegion.defaultValue
        SessionScrollRegion.reduce(value: &value, nextValue: { measured })
        // SwiftUI folds default values from the other branches of the panel too.
        SessionScrollRegion.reduce(value: &value, nextValue: { .zero })
        SessionScrollRegion.reduce(value: &value, nextValue: { .zero })
        XCTAssertEqual(value, measured)
        XCTAssertTrue(value.contains(CGPoint(x: 100, y: 208)))
    }
    func testScrollViewportUpdatesWhenFooterOrLayoutChanges() {
        var value = CGRect(x: 0, y: 139, width: 360, height: 300)
        let resized = CGRect(x: 0, y: 139, width: 360, height: 260)
        SessionScrollRegion.reduce(value: &value, nextValue: { resized })
        XCTAssertEqual(value, resized)
        XCTAssertEqual(SessionScrollRegion.defaultValue, .zero)
    }
}
