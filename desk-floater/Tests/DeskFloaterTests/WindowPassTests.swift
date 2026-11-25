import AppKit
import SwiftUI
import XCTest
@testable import DeskFloater

/// The floater's windows are moved, resized and ordered only between
/// AppKit's layout passes, never from inside one.
///
/// SwiftUI runs a view's geometry and change actions inside its window's
/// update-constraints or layout pass. A window resized or ordered from there
/// needs another pass, and AppKit allows a window only as many passes in a
/// row as it has views: two for the floater and the halo. Past that it
/// throws, and the app quits (the crash reports' _crashOnException inside
/// _NSViewUpdateConstraints, whenever a reply arrived).
final class WindowPassTests: XCTestCase {
    /// Counts how deep the floater's hosting views are in a pass.
    @MainActor static var depth = 0
    /// Window changes made while a pass was under way.
    @MainActor static var changesInPass: [String] = []

    final class Host: NSHostingView<FloaterView> {
        override func updateConstraints() {
            WindowPassTests.depth += 1
            defer { WindowPassTests.depth -= 1 }
            super.updateConstraints()
        }

        override func layout() {
            WindowPassTests.depth += 1
            defer { WindowPassTests.depth -= 1 }
            super.layout()
        }
    }

    /// A panel that records changes made inside a pass. It is never seen and
    /// never takes a click, so the test puts nothing on the screen.
    final class Panel: NSPanel {
        var name = ""

        override var ignoresMouseEvents: Bool {
            get { true }
            set {}
        }

        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            note("setFrame \(frameRect.size == frame.size ? "move" : "resize")")
            super.setFrame(frameRect, display: flag)
        }

        override func setFrameOrigin(_ point: NSPoint) {
            note("setFrameOrigin")
            super.setFrameOrigin(point)
        }

        override func orderFrontRegardless() {
            note("orderFrontRegardless")
            super.orderFrontRegardless()
        }

        override func orderOut(_ sender: Any?) {
            note("orderOut")
            super.orderOut(sender)
        }

        private func note(_ change: String) {
            MainActor.assumeIsolated {
                if WindowPassTests.depth > 0 {
                    WindowPassTests.changesInPass.append("\(name): \(change)")
                }
            }
        }
    }

    @MainActor
    private func run(parkedAt place: (NSRect) -> NSPoint, style: ReplyMotion.Style) throws -> [String] {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no screen to place windows on")
        }
        let visible = screen.visibleFrame
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("df-passes-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let model = FloaterModel(repoRoot: "/nonexistent", fmHome: home)
        model.keysTrusted = true
        model.screenTrusted = true
        let mover = WindowMover()
        mover.motion.style = style
        var panels: [Panel] = []
        for (name, part) in [("floater", FloaterView.Part.card), ("card", .bubble), ("halo", .halo)] {
            let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 89, height: 52),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.name = name
            panel.alphaValue = 0
            panel.isReleasedWhenClosed = false
            let host = Host(rootView: FloaterView(model: model, mover: mover, part: part))
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: panel.frame.size)
            panel.contentView = host
            panels.append(panel)
        }
        let floater = panels[0]
        defer { panels.forEach { $0.orderOut(nil) } }
        floater.setFrameOrigin(place(visible))
        mover.bubble = panels[1]
        mover.halo = panels[2]
        mover.window = floater
        floater.orderFrontRegardless()
        // On screen, SwiftUI hands a window's geometry and change actions
        // over from inside the window's own passes; a test process gets no
        // display cycle of its own, so each turn runs those passes itself.
        func turn(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            repeat {
                for panel in panels {
                    panel.updateConstraintsIfNeeded()
                    panel.layoutIfNeeded()
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while Date() < end
        }
        WindowPassTests.changesInPass = []
        turn(0.2)
        // A screenshot, then a talk, and a reply arriving while it is sent.
        model.status = "1 shot stacked"
        turn(0.2)
        model.mode = .recording
        model.status = "Listening"
        turn(0.3)
        model.mode = .busy
        model.status = "Sending…"
        model.caption = Reply(id: 1, time: Date(), text: "x", eye: "The fix is on its way.",
                              full: "The fix is on its way.")
        turn(0.2)
        model.speaking = true
        model.mode = .idle
        model.status = "Sent"
        turn(1.2)
        model.status = FloaterModel.restingStatus
        model.speaking = false
        model.toggleCaptionExpanded()
        turn(0.4)
        model.caption = Reply(id: 2, time: Date(), text: "y", eye: "Another reply, a little longer than the first.",
                              full: "Another reply, a little longer than the first.")
        turn(0.4)
        model.dismissCaption()
        turn(1.5)
        return WindowPassTests.changesInPass
    }

    @MainActor
    func testNoWindowChangesInsideALayoutPass() throws {
        let places: [(String, (NSRect) -> NSPoint)] = [
            ("parked in a corner", { NSPoint(x: $0.minX - 31, y: $0.maxY - 72) }),
            ("on screen, top right", { NSPoint(x: $0.maxX - 113, y: $0.maxY - 252) }),
            ("bottom left", { NSPoint(x: $0.minX + 20, y: $0.minY + 10) }),
        ]
        for style in [ReplyMotion.Style.calm, .full, .off] {
            for (place, origin) in places {
                let changes = try run(parkedAt: origin, style: style)
                XCTAssertEqual(changes, [], "\(place), motion \(style): windows changed inside a layout pass")
            }
        }
    }
}
