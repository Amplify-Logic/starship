import AppKit
import SwiftUI
import XCTest
@testable import DeskFloater

/// The floater's three windows (Talk and Show, the reply card, and the
/// card's halo) each hold their SwiftUI view inside a plain content view.
///
/// A hosting view that is itself a window's content view recomputes the
/// window's size limits from inside AppKit's constraint pass
/// (NSHostingView.updateWindowContentSizeExtremaIfNecessary, which returns at
/// once for any other view). When a reply arrived or the status line changed,
/// that recomputation found the window resized and asked for another pass,
/// and AppKit stops the app once a window has had more passes in a row than
/// it has views: two here. Every crash report ended there.
final class FloaterWindowsTests: XCTestCase {
    @MainActor
    func testNoWindowHasAHostingViewAsItsContentView() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("df-windows-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let model = FloaterModel(repoRoot: "/nonexistent", fmHome: home)
        // Built and checked, never shown.
        let panel = FloaterPanel(model: model)
        let windows: [(String, NSWindow?)] = [("floater", panel), ("card", panel.mover.bubble),
                                             ("halo", panel.mover.halo)]
        for (name, window) in windows {
            let content = try XCTUnwrap(window?.contentView, name)
            XCTAssertFalse(content is NSHostingView<FloaterView>, "\(name): the hosting view is the content view")
            let hosting = try XCTUnwrap(content.subviews.first as? NSHostingView<FloaterView>, name)
            XCTAssertEqual(hosting.sizingOptions, [], "\(name): WindowMover sizes the window, not SwiftUI")
            XCTAssertEqual(hosting.frame, content.bounds, "\(name): the view fills its window")
            XCTAssertEqual(hosting.autoresizingMask, [.width, .height], "\(name): and follows its size")
            XCTAssertFalse(window?.isVisible ?? true, "\(name): nothing reaches the screen")
        }
    }
}
