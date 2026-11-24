import AppKit
import SwiftUI
import XCTest
@testable import DeskFloater

final class FloaterLayoutTests: XCTestCase {
    // A laptop screen's visible frame: the menu bar above, the Dock below.
    private let visible = NSRect(x: 0, y: 70, width: 1512, height: 875)
    private let card = CGSize(width: 89, height: 52)
    private let bubble = CGSize(width: 260, height: 120)

    private func parked(_ x: CGFloat, _ y: CGFloat) -> NSRect {
        NSRect(origin: NSPoint(x: x, y: y), size: card)
    }

    /// Floaters pushed almost wholly off each corner and edge, a few points
    /// left to grab, and one in the open.
    private var places: [(String, NSRect)] {
        [
            ("bottom-left corner", parked(visible.minX - 80, visible.minY - 44)),
            ("top-left corner", parked(visible.minX - 80, visible.maxY - 8)),
            ("top-right corner", parked(visible.maxX - 9, visible.maxY - 8)),
            ("bottom-right corner", parked(visible.maxX - 9, visible.minY - 44)),
            ("left edge", parked(visible.minX - 80, visible.midY)),
            ("right edge", parked(visible.maxX - 9, visible.midY)),
            ("top edge", parked(visible.midX, visible.maxY - 8)),
            ("bottom edge", parked(visible.midX, visible.minY - 44)),
            ("in the open", parked(600, 500)),
        ]
    }

    func testTheBubbleOpensWhollyOnScreenWhereverTheFloaterIsParked() {
        for (place, floater) in places {
            let rect = FloaterLayout.bubbleFrame(bubble, beside: floater, on: visible)
            XCTAssertEqual(rect.size, bubble, place)
            XCTAssertTrue(visible.contains(rect), "\(place): \(rect) is not wholly on \(visible)")
            XCTAssertFalse(rect.intersects(floater), "\(place): the bubble covers the floater")
        }
    }

    func testTheBubbleOpensTowardTheScreensMiddle() {
        let topRight = FloaterLayout.bubbleFrame(bubble, beside: parked(1300, 850), on: visible)
        XCTAssertLessThan(topRight.maxY, 850, "below a floater in the top half")
        XCTAssertEqual(topRight.maxX, 1389, "lined up with its right edge, growing left")

        let bottomLeft = FloaterLayout.bubbleFrame(bubble, beside: parked(100, 120), on: visible)
        XCTAssertGreaterThan(bottomLeft.minY, 172, "above a floater in the bottom half")
        XCTAssertEqual(bottomLeft.minX, 100, "lined up with its left edge, growing right")
    }

    func testABubbleTallerThanTheScreenKeepsItsTopOnIt() {
        let tall = FloaterLayout.bubbleFrame(CGSize(width: 340, height: 2000),
                                             beside: parked(1300, 850), on: visible)
        XCTAssertEqual(tall.maxY, visible.maxY)
    }

    func testTheFloaterStaysParkedOffScreenWhenItsCardResizes() {
        let floater = parked(visible.minX - 80, visible.minY - 44)
        let anchor = FloaterLayout.anchor(for: floater, on: visible)
        XCTAssertEqual(anchor.frame(card), floater, "the same size changes nothing")

        let withStatus = anchor.frame(CGSize(width: 128, height: 67))
        XCTAssertEqual(withStatus.minX, floater.minX, "never pulled onto the screen")
        XCTAssertEqual(withStatus.minY, floater.minY)
        XCTAssertEqual(anchor.frame(card), floater, "and back to where it was")

        let topRight = parked(visible.maxX - 9, visible.maxY - 8)
        let grown = FloaterLayout.anchor(for: topRight, on: visible).frame(CGSize(width: 128, height: 67))
        XCTAssertEqual(grown.maxX, topRight.maxX)
        XCTAssertEqual(grown.maxY, topRight.maxY)
    }

    func testTheScreenIsTheOneHoldingMostOfTheFloaterElseTheNearest() {
        let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let screens = [visible, left]
        XCTAssertEqual(FloaterLayout.screen(for: parked(-60, 500), among: screens), left)
        XCTAssertEqual(FloaterLayout.screen(for: parked(-80, 500), among: screens), left)
        XCTAssertEqual(FloaterLayout.screen(for: parked(-9, 500), among: screens), visible)
        XCTAssertEqual(FloaterLayout.screen(for: parked(1600, 20), among: screens), visible,
                       "wholly off every screen: the nearest")
        XCTAssertNil(FloaterLayout.screen(for: parked(0, 0), among: []))
    }

    @MainActor
    func testTheStatusLineShowsOnlyWhileThereIsSomethingToSay() {
        XCTAssertFalse(FloaterModel.statusShown(FloaterModel.restingStatus, mode: .idle))
        XCTAssertTrue(FloaterModel.statusShown("1 shot stacked", mode: .idle))
        XCTAssertTrue(FloaterModel.statusShown("Keys off - click !", mode: .idle))
        XCTAssertTrue(FloaterModel.statusShown(FloaterModel.savedRetrying, mode: .idle))
        XCTAssertTrue(FloaterModel.statusShown("Sent", mode: .idle))
        XCTAssertTrue(FloaterModel.statusShown(FloaterModel.restingStatus, mode: .busy))
    }

    /// The floater's own windows: one parked almost wholly off the bottom-left
    /// corner of the screen stays there while a reply opens and its status
    /// line comes and goes, and the reply's bubble lands wholly on the screen.
    @MainActor
    func testAReplyLeavesTheParkedFloaterWhereItIsAndOpensOnScreen() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no screen to place windows on")
        }
        let visible = screen.visibleFrame
        func window() -> NSWindow {
            NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                     backing: .buffered, defer: false)
        }
        let floater = window()
        let bubbleWindow = window()
        let parkedFrame = parked(visible.minX - 80, visible.minY - 44)
        floater.setFrame(parkedFrame, display: false)
        let mover = WindowMover()
        mover.bubble = bubbleWindow
        mover.window = floater

        mover.fit(card)
        mover.fitBubble(bubble)
        XCTAssertEqual(floater.frame, parkedFrame, "the reply moved the floater")
        XCTAssertTrue(bubbleWindow.isVisible)
        XCTAssertTrue(visible.contains(bubbleWindow.frame), "\(bubbleWindow.frame) is not wholly on \(visible)")

        mover.fit(CGSize(width: 128, height: 67))
        XCTAssertEqual(floater.frame.origin, parkedFrame.origin, "the status line moved the floater")
        mover.fit(card)
        XCTAssertEqual(floater.frame, parkedFrame)
        XCTAssertTrue(visible.contains(bubbleWindow.frame))

        mover.fitBubble(.zero)
        XCTAssertFalse(bubbleWindow.isVisible, "a closed reply hides its bubble")
        XCTAssertEqual(floater.frame, parkedFrame)
        bubbleWindow.orderOut(nil)
        floater.orderOut(nil)
    }

    /// The real card in a real window, parked in each quarter of the screen:
    /// Talk keeps its centre on screen, and Show beside it, while the status line comes
    /// for recording, says Sent, and goes again at rest, so a second click to
    /// stop lands where the first one did.
    @MainActor
    func testTalkAndShowStayPutAsTheStatusLineComesAndGoes() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no screen to place windows on")
        }
        let visible = screen.visibleFrame
        let corners = [
            ("top right", NSPoint(x: visible.maxX - 200, y: visible.maxY - 100)),
            ("top left", NSPoint(x: visible.minX + 100, y: visible.maxY - 100)),
            ("bottom left", NSPoint(x: visible.minX + 100, y: visible.minY + 50)),
            ("bottom right", NSPoint(x: visible.maxX - 200, y: visible.minY + 50)),
        ]
        let model = FloaterModel(repoRoot: "/nonexistent", fmHome: "/nonexistent")
        model.keysTrusted = true
        model.screenTrusted = true
        for (place, origin) in corners {
            model.mode = .idle
            model.status = FloaterModel.restingStatus
            let mover = WindowMover()
            let hosting = NSHostingView(rootView: FloaterView(model: model, mover: mover, part: .card))
            hosting.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(origin: origin, size: CGSize(width: 89, height: 52)),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            mover.window = window

            /// Where Talk is on screen: the middle of its coloured circle,
            /// the only saturated paint on the card, found in the card's
            /// rendered pixels and placed by the window's frame.
            func talkCentre() -> NSPoint? {
                for _ in 0..<2 {
                    hosting.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                guard rep.bitsPerSample == 8, rep.samplesPerPixel == 4, let data = rep.bitmapData else { return nil }
                let alphaFirst = rep.bitmapFormat.contains(.alphaFirst)
                let scale = CGFloat(rep.pixelsWide) / hosting.bounds.width
                var sumX: CGFloat = 0, sumY: CGFloat = 0, count: CGFloat = 0
                for py in 0..<rep.pixelsHigh {
                    for px in 0..<rep.pixelsWide {
                        let pixel = data + py * rep.bytesPerRow + px * 4
                        let alpha = alphaFirst ? pixel[0] : pixel[3]
                        let rgb = alphaFirst ? [pixel[1], pixel[2], pixel[3]] : [pixel[0], pixel[1], pixel[2]]
                        let high = CGFloat(rgb.max()!), low = CGFloat(rgb.min()!)
                        guard alpha > 230, high > 0, (high - low) / high > 0.5 else { continue }
                        sumX += CGFloat(px)
                        sumY += CGFloat(py)
                        count += 1
                    }
                }
                guard count > 0 else { return nil }
                let frame = window.frame
                return NSPoint(x: frame.minX + (sumX / count + 0.5) / scale,
                               y: frame.maxY - (sumY / count + 0.5) / scale)
            }

            let resting = try XCTUnwrap(talkCentre(), "\(place): Talk is on the card")
            XCTAssertEqual(window.frame.size, CGSize(width: 89, height: 52), "\(place): the card hugs the buttons")
            for (mode, status) in [(FloaterModel.Mode.recording, "Listening"), (.idle, "Sent"),
                                   (.idle, FloaterModel.restingStatus)] {
                model.mode = mode
                model.status = status
                let now = try XCTUnwrap(talkCentre(), "\(place), \(status): Talk is on the card")
                XCTAssertEqual(window.frame.height > 52, status != FloaterModel.restingStatus,
                               "\(place), \(status): the status line shows only while there is something to say")
                XCTAssertEqual(now.x, resting.x, accuracy: 0.5, "\(place), \(status): Talk moved sideways")
                XCTAssertEqual(now.y, resting.y, accuracy: 0.5, "\(place), \(status): Talk moved up or down")
            }
            window.orderOut(nil)
        }
    }
}
