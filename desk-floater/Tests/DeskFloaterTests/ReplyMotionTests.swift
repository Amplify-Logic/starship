import AppKit
import SwiftUI
import XCTest
@testable import DeskFloater

/// The reply card's Unfold motion: where the card goes, the phases it moves
/// through, the floater's windows while it does, and the motion's own switch
/// and settings.
final class ReplyMotionTests: XCTestCase {
    private let visible = NSRect(x: 0, y: 70, width: 1512, height: 875)
    private let floaterSize = CGSize(width: 89, height: 52)
    private let card = CGSize(width: 300, height: 140)

    private func parked(_ x: CGFloat, _ y: CGFloat) -> NSRect {
        NSRect(origin: NSPoint(x: x, y: y), size: floaterSize)
    }

    // MARK: where the card goes

    /// On screen, in each quarter, the card grows around the floater from the
    /// corner it keeps still, toward the middle, wholly on screen, and starts
    /// from the floater itself.
    func testOnScreenTheCardUnfoldsAroundTheFloaterFromItsStillCorner() throws {
        let places = [
            ("top right", parked(1300, 800)),
            ("top left", parked(100, 800)),
            ("bottom left", parked(100, 120)),
            ("bottom right", parked(1300, 120)),
        ]
        for (place, floater) in places {
            let anchor = FloaterLayout.anchor(for: floater, on: visible)
            let rect = try XCTUnwrap(FloaterLayout.inPlaceFrame(card, anchor: anchor, on: visible), place)
            XCTAssertEqual(rect.size, card, place)
            XCTAssertTrue(rect.contains(floater), "\(place): the card is around the floater")
            XCTAssertTrue(visible.contains(rect), "\(place): \(rect) is not wholly on \(visible)")
            XCTAssertEqual(rect.midX < floater.midX, anchor.growsLeft, "\(place): grows toward the middle")
            XCTAssertEqual(rect.midY < floater.midY, anchor.growsDown, "\(place): grows toward the middle")
            XCTAssertEqual(FloaterLayout.unfoldStart(floater: floater, card: rect, on: visible), floater,
                           "\(place): it unfolds out of the floater")
        }
    }

    /// Parked mostly off screen, the card does not fit around the floater:
    /// it opens beside it wholly on screen, and unfolds from a piece of the
    /// part of the floater still on screen, never from off screen.
    func testParkedOffScreenTheCardOpensBesideAndUnfoldsFromWhatIsLeftOnScreen() {
        let places = [
            ("top-right corner", parked(visible.maxX - 9, visible.maxY - 8)),
            ("bottom-left corner", parked(visible.minX - 80, visible.minY - 44)),
            ("right edge", parked(visible.maxX - 9, visible.midY)),
        ]
        for (place, floater) in places {
            let anchor = FloaterLayout.anchor(for: floater, on: visible)
            XCTAssertNil(FloaterLayout.inPlaceFrame(card, anchor: anchor, on: visible),
                         "\(place): a card around it would leave the screen")
            let rect = FloaterLayout.bubbleFrame(card, beside: floater, on: visible)
            XCTAssertTrue(visible.contains(rect), place)
            let start = FloaterLayout.unfoldStart(floater: floater, card: rect, on: visible)
            XCTAssertTrue(rect.contains(start), "\(place): \(start) starts inside the card \(rect)")
            XCTAssertLessThanOrEqual(start.width, floater.intersection(visible).width, place)
            XCTAssertLessThanOrEqual(start.height, floater.intersection(visible).height, place)
        }
    }

    // MARK: the phases

    @MainActor
    private func waitFor(_ phase: CardMotion.Phase, of motion: CardMotion, within seconds: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(seconds)
        while motion.phase != phase && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(motion.phase, phase)
    }

    /// Off: the card simply appears and goes, with no phase between.
    @MainActor
    func testOffTheCardAppearsAndGoesAtOnce() {
        let motion = CardMotion()
        motion.style = .off
        motion.show()
        XCTAssertEqual(motion.phase, .shown)
        XCTAssertEqual(motion.unfold, 1)
        XCTAssertEqual(motion.fade, 1)
        motion.hide()
        XCTAssertEqual(motion.phase, .hidden)
    }

    /// Calm: the card waits for its window to be placed, unfolds, is shown,
    /// and folds away again, keeping what it showed until it is gone.
    @MainActor
    func testCalmUnfoldsOncePlacedAndFoldsAway() {
        let motion = CardMotion()
        let content = CardContent(caption: Reply(id: 1, time: Date(), text: "x", eye: "Done.", full: "Done."))
        motion.keep(content)
        motion.show()
        XCTAssertEqual(motion.phase, .arriving)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(motion.phase, .arriving, "nothing moves before the window is placed")
        motion.placed()
        waitFor(.shown, of: motion)
        XCTAssertEqual(motion.unfold, 1)
        XCTAssertEqual(motion.words, 1)

        motion.hide()
        XCTAssertEqual(motion.phase, .leaving)
        motion.keep(CardContent())
        XCTAssertEqual(motion.held, content, "the card keeps its words while it folds away")
        waitFor(.hidden, of: motion)
        XCTAssertEqual(motion.unfold, 0)
        XCTAssertNil(motion.held)
    }

    /// A reply that lands while the card folds away turns it around.
    @MainActor
    func testANewReplyMidLeaveTurnsTheCardAround() {
        let motion = CardMotion()
        motion.style = .full
        motion.show()
        motion.placed()
        waitFor(.shown, of: motion)
        motion.hide()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(motion.phase, .leaving)
        motion.show()
        XCTAssertEqual(motion.phase, .arriving, "turned around without being placed again")
        waitFor(.shown, of: motion)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(motion.phase, .shown, "the old leave does not finish after the turn")
    }

    /// A reply that lands while the card folds away is what the card holds
    /// once it turns around, so its next leave folds away that reply's words.
    @MainActor
    func testTheTurnedAroundCardHoldsTheNewReply() {
        let motion = CardMotion()
        let first = CardContent(caption: Reply(id: 1, time: Date(), text: "x", eye: "One.", full: "One."))
        let second = CardContent(caption: Reply(id: 2, time: Date(), text: "y", eye: "Two.", full: "Two."))
        motion.keep(first)
        motion.show()
        motion.placed()
        waitFor(.shown, of: motion)
        motion.hide()
        motion.keep(second)
        XCTAssertEqual(motion.held, first, "the leaving card keeps its own words")
        motion.show()
        waitFor(.shown, of: motion)
        motion.hide()
        XCTAssertEqual(motion.held, second)
    }

    /// A reply that lands while the card folds away and stays hidden is held
    /// when the card next shows.
    @MainActor
    func testAReplyThatLandsMidLeaveIsHeldWhenTheCardNextShows() {
        let motion = CardMotion()
        let first = CardContent(caption: Reply(id: 1, time: Date(), text: "x", eye: "One.", full: "One."))
        let second = CardContent(caption: Reply(id: 2, time: Date(), text: "y", eye: "Two.", full: "Two."))
        motion.keep(first)
        motion.show()
        motion.placed()
        waitFor(.shown, of: motion)
        motion.hide()
        motion.keep(second)
        waitFor(.hidden, of: motion)
        XCTAssertNil(motion.held)
        motion.show()
        XCTAssertEqual(motion.held, second)
    }

    /// With the Mac's Reduce motion on, the card arrives and leaves as a
    /// plain short fade at its final size.
    @MainActor
    func testReduceMotionIsAPlainShortFade() {
        let motion = CardMotion()
        motion.reduceMotion = true
        XCTAssertFalse(motion.grows)
        motion.show()
        motion.placed()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(motion.unfold, 1, "no growth: the paper is at its final size")
        waitFor(.shown, of: motion, within: 0.6)
        motion.hide()
        waitFor(.hidden, of: motion, within: 0.6)
    }

    // MARK: the windows

    @MainActor
    private func windows(at frame: NSRect) -> (mover: WindowMover, floater: NSWindow, card: NSWindow, halo: NSWindow) {
        let floater = Panel.make(), card = Panel.make(), halo = Panel.make()
        floater.setFrame(frame, display: false)
        let mover = WindowMover()
        mover.bubble = card
        mover.halo = halo
        mover.window = floater
        mover.fit(floaterSize, statusShown: false)
        return (mover, floater, card, halo)
    }

    /// The card unfolds around the parked floater without moving it, takes
    /// no click until it has arrived, and gives the floater back its own
    /// outline and shadow once folded away.
    @MainActor
    func testTheCardUnfoldsAroundTheFloaterWithoutMovingItOrCatchingClicksEarly() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no screen to place windows on")
        }
        let visible = screen.visibleFrame
        let parkedFrame = parked(visible.maxX - 89 - 24, visible.maxY - 52 - 200)
        let (mover, floater, card, halo) = windows(at: parkedFrame)
        defer { [floater, card, halo].forEach { $0.orderOut(nil) } }

        mover.motion.show()
        XCTAssertTrue(mover.cardInPlace)
        mover.fitBubble(self.card)
        XCTAssertEqual(floater.frame, parkedFrame, "the reply moved the floater")
        XCTAssertTrue(card.frame.contains(parkedFrame), "\(card.frame) is not around the floater")
        XCTAssertTrue(visible.contains(card.frame))
        XCTAssertEqual(halo.frame, card.frame.insetBy(dx: -FloaterLayout.haloMargin, dy: -FloaterLayout.haloMargin))
        XCTAssertTrue(card.ignoresMouseEvents, "no click lands on a card still unfolding")
        XCTAssertTrue(mover.coversFloater)
        XCTAssertFalse(floater.hasShadow, "the floater's own shadow would fall on the card")
        XCTAssertEqual(mover.unfoldStart.size, floaterSize, "it unfolds out of the floater")

        waitFor(.shown, of: mover.motion)
        XCTAssertFalse(card.ignoresMouseEvents, "the arrived card takes its clicks")

        mover.motion.hide()
        XCTAssertTrue(card.ignoresMouseEvents)
        waitFor(.hidden, of: mover.motion)
        XCTAssertFalse(mover.coversFloater)
        XCTAssertTrue(floater.hasShadow)
        mover.fitBubble(.zero)
        XCTAssertFalse(card.isVisible)
        XCTAssertFalse(halo.isVisible)
        XCTAssertEqual(floater.frame, parkedFrame)
    }

    /// Parked almost off the screen's corner, the card opens beside the
    /// floater wholly on screen, and the floater stays where it is.
    @MainActor
    func testParkedInACornerTheCardOpensBesideAndTheFloaterStays() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no screen to place windows on")
        }
        let visible = screen.visibleFrame
        let parkedFrame = parked(visible.minX - 80, visible.minY - 44)
        let (mover, floater, card, halo) = windows(at: parkedFrame)
        defer { [floater, card, halo].forEach { $0.orderOut(nil) } }

        mover.motion.show()
        mover.fitBubble(self.card)
        XCTAssertFalse(mover.cardInPlace, "a card around it would leave the screen")
        XCTAssertFalse(mover.coversFloater)
        XCTAssertEqual(floater.frame, parkedFrame)
        XCTAssertTrue(visible.contains(card.frame), "\(card.frame) is not wholly on \(visible)")
        XCTAssertFalse(card.frame.intersects(parkedFrame))
    }

    /// Off, the card opens beside the floater as the bubble always did.
    @MainActor
    func testWithMotionOffTheCardOpensBesideAsBefore() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no screen to place windows on")
        }
        let visible = screen.visibleFrame
        let parkedFrame = parked(visible.maxX - 89 - 24, visible.maxY - 52 - 200)
        let (mover, floater, card, halo) = windows(at: parkedFrame)
        defer { [floater, card, halo].forEach { $0.orderOut(nil) } }

        mover.motion.style = .off
        mover.motion.show()
        mover.fitBubble(self.card)
        XCTAssertFalse(mover.cardInPlace)
        XCTAssertEqual(card.frame, FloaterLayout.bubbleFrame(self.card, beside: parkedFrame, on: visible))
        XCTAssertFalse(card.ignoresMouseEvents, "shown at once, so clickable at once")
    }

    /// The real card: a reply unfolds it around the floater and is shown;
    /// dismissed, it folds away with its words still on it and is gone.
    @MainActor
    func testAReplyUnfoldsTheRealCardAndDismissingFoldsItAway() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no screen to place windows on")
        }
        let visible = screen.visibleFrame
        let parkedFrame = parked(visible.maxX - 89 - 24, visible.maxY - 52 - 200)
        let (mover, floater, card, halo) = windows(at: parkedFrame)
        defer { [floater, card, halo].forEach { $0.orderOut(nil) } }
        let model = FloaterModel(repoRoot: "/nonexistent", fmHome: "/nonexistent")
        let hosting = NSHostingView(rootView: FloaterView(model: model, mover: mover, part: .bubble))
        hosting.sizingOptions = []
        card.contentView = hosting
        func turn(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            repeat {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            } while Date() < end
        }
        turn(0.1)
        XCTAssertFalse(card.isVisible, "no reply, no card")

        model.caption = Reply(id: 1, time: Date(), text: "x", eye: "The fix is on its way.", full: "The fix is on its way.")
        turn(0.1)
        XCTAssertTrue(card.isVisible)
        XCTAssertTrue(mover.cardInPlace)
        XCTAssertTrue(card.frame.contains(parkedFrame), "\(card.frame) is not around the floater")
        waitFor(.shown, of: mover.motion)
        XCTAssertFalse(card.ignoresMouseEvents)

        let size = card.frame.size
        model.dismissCaption()
        turn(0.1)
        XCTAssertEqual(mover.motion.phase, .leaving)
        XCTAssertTrue(card.isVisible, "it folds away rather than vanishing")
        XCTAssertEqual(card.frame.size, size, "with its words still on it")
        waitFor(.hidden, of: mover.motion)
        turn(0.1)
        XCTAssertFalse(card.isVisible)
        XCTAssertEqual(floater.frame, parkedFrame)
    }

    /// The real panel with Full motion, parked mostly off the screen's
    /// top-left corner as in the live run (floater at -31,877 on a visible
    /// frame of y 81..949): a reply opens the card beside the floater, wholly
    /// on screen, and the floater stays where it was parked.
    @MainActor
    func testFullMotionParkedInACornerOpensTheRealCardBeside() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no screen to place windows on")
        }
        let visible = screen.visibleFrame
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("df-full-corner-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        // Full, as kept from an earlier pick, so no status line is up.
        let setting = ReplyMotion.path(home: home)
        try FileManager.default.createDirectory(atPath: (setting as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try "motion=full\nlast=full\n".write(toFile: setting, atomically: true, encoding: .utf8)
        let model = FloaterModel(repoRoot: "/nonexistent", fmHome: home)
        XCTAssertEqual(model.motion.style, .full)
        // Its card and halo stay off screen, and the floater is never shown.
        let panel = FloaterPanel(model: model, makePanel: Panel.make)
        defer { NSApp.windows.forEach { $0.orderOut(nil) } }
        func turn(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            } while Date() < end
        }
        turn(0.2)
        let parkedOrigin = NSPoint(x: visible.minX - 31, y: visible.maxY - 72)
        // Dragged there: the drag moves the floater and ends.
        panel.setFrameOrigin(parkedOrigin)
        panel.mover.end()
        turn(0.2)
        let parkedFrame = panel.frame

        model.caption = Reply(id: 1, time: Date(), text: "x", eye: "The fix is on its way.", full: "The fix is on its way.")
        turn(1.5)
        let card = try XCTUnwrap(NSApp.windows.first { $0 !== panel && $0.isVisible && !$0.ignoresMouseEvents },
                                 "the arrived card is up and takes its clicks")
        XCTAssertEqual(panel.frame, parkedFrame, "the reply moved the floater")
        XCTAssertTrue(visible.contains(card.frame), "\(card.frame) is not wholly on \(visible)")
        XCTAssertFalse(card.frame.intersects(parkedFrame), "a card around it would leave the screen")
    }

    // MARK: the setting

    func testTheSettingReadsItsLinesAndFallsBackToCalm() {
        XCTAssertEqual(ReplyMotion.parse(""), ReplyMotion())
        XCTAssertEqual(ReplyMotion().style, .calm)
        XCTAssertEqual(ReplyMotion().stay, 15)
        let read = ReplyMotion.parse("motion=off\nlast=full\nstay=30\n")
        XCTAssertEqual(read.style, .off)
        XCTAssertEqual(read.last, .full)
        XCTAssertEqual(read.stay, 30)
        XCTAssertEqual(ReplyMotion.parse(read.text), read)
        let odd = ReplyMotion.parse("motion=wild\nlast=off\nstay=1\nnoise\n")
        XCTAssertEqual(odd, ReplyMotion(), "unreadable lines keep the defaults")
    }

    func testOneClickTurnsTheMotionOffAndBringsBackWhatItWas() {
        let full = ReplyMotion().with(style: .full)
        let off = full.toggled()
        XCTAssertEqual(off.style, .off)
        XCTAssertEqual(off.toggled().style, .full)
        XCTAssertEqual(ReplyMotion().toggled().toggled().style, .calm)
    }

    /// The switch, the motion and the stay are kept per home across restarts.
    @MainActor
    func testTheMotionSettingIsKeptAcrossRestarts() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("motion-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let model = FloaterModel(repoRoot: home, fmHome: home)
        XCTAssertEqual(model.motion, ReplyMotion(), "a home that never touched it gets calm")
        model.setMotionStyle(.full)
        model.setCaptionStay(30)
        model.toggleMotion()
        XCTAssertEqual(model.motion.style, .off)
        XCTAssertEqual(model.status, "Motion off")

        let restarted = FloaterModel(repoRoot: home, fmHome: home)
        XCTAssertEqual(restarted.motion.style, .off)
        XCTAssertEqual(restarted.motion.stay, 30)
        restarted.toggleMotion()
        XCTAssertEqual(restarted.motion.style, .full, "one click brings back the motion it had")
        XCTAssertEqual(FloaterModel(repoRoot: home, fmHome: home).motion.style, .full)
    }

    /// A right-click on the card offers the motion and how long a reply stays.
    @MainActor
    func testTheMenuOffersTheMotionAndTheStay() {
        let model = FloaterModel(repoRoot: "/nonexistent", fmHome: "/nonexistent")
        let hosting = NSHostingView(rootView: FloaterView(model: model, mover: WindowMover()))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let point = NSPoint(x: hosting.frame.width / 2, y: 8)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1)!
        let menu = hosting.hitTest(point)?.menu(for: event)
        let motion = menu?.items.first { $0.title == "Reply motion" }?.submenu?.items.map(\.title)
        XCTAssertEqual(motion, ["Off", "Calm", "Full"])
        let stays = menu?.items.first { $0.title == "Reply stays" }?.submenu?.items.map(\.title)
        XCTAssertEqual(stays, ["8 s", "15 s", "30 s", "1 min"])
    }
}

extension ReplyMotionTests {
    /// A panel for tests that takes every order to show or hide and remembers
    /// it, without ever putting the window on a screen: no test puts a floater
    /// window where the person at this Mac would see it. `isVisible` reports what
    /// the code under test asked for.
    final class Panel: NSPanel {
        private var shown = false

        static func make(_ rect: NSRect = NSRect(x: 0, y: 0, width: 10, height: 10)) -> NSPanel {
            Panel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: false)
        }

        override var isVisible: Bool { shown }
        override func orderFrontRegardless() { shown = true }
        override func orderFront(_ sender: Any?) { shown = true }
        override func makeKeyAndOrderFront(_ sender: Any?) { shown = true }
        override func orderOut(_ sender: Any?) { shown = false }
    }
}

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
extension ReplyMotionTests {
    @MainActor
    func testNoWindowHasAHostingViewAsItsContentView() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("df-windows-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let model = FloaterModel(repoRoot: "/nonexistent", fmHome: home)
        // Built and checked, never shown.
        let panel = FloaterPanel(model: model, makePanel: ReplyMotionTests.Panel.make)
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
