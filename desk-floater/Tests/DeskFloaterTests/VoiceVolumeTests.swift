import AppKit
import SwiftUI
import XCTest
@testable import DeskFloater

/// The floater's voice controls: the volume and mute its right-click menu
/// reads and sets, and the reply bubble's offer, Stop and Hear again, whose
/// taps only run the home's scripts, here stand-ins that record what they
/// were asked.
final class VoiceVolumeTests: XCTestCase {
    /// The voice volume and mute left the floater's face for a right-click on
    /// its card, which the hosting view must answer with that menu.
    @MainActor
    func testARightClickOnTheCardOffersTheVoiceVolumeAndMute() {
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
        XCTAssertEqual(menu?.items.map(\.title), ["Voice volume", "Mute voice", "Turn reply bubble off"])
        let levels = menu?.items.first?.submenu?.items.map(\.title) ?? []
        XCTAssertTrue(levels.contains("100% (system volume)"), "the levels are offered: \(levels)")
        XCTAssertTrue(levels.contains("200%"))
    }

    func testLevelsOutsideTheRangeAreNotLevels() {
        XCTAssertEqual(VoiceVolume.parse("60\n"), 60)
        XCTAssertEqual(VoiceVolume.parse("200"), 200)
        XCTAssertNil(VoiceVolume.parse("201"))
        XCTAssertNil(VoiceVolume.parse("loud"))
        XCTAssertNil(VoiceVolume.parse(nil))
        XCTAssertEqual(VoiceVolume.clamp(-5), 0)
        XCTAssertEqual(VoiceVolume.clamp(250), 200)
    }

    /// The menu reads the kept level and keeps a new one
    /// through bin/fm-speak.sh, here a stand-in that records what it was asked.
    @MainActor
    func testTheVolumeControlReadsAndKeepsTheLevelThroughSpeak() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-volume-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("speak.log")
        let stub = bin.appendingPathComponent("fm-speak.sh")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        case "$1" in
          --volume) [ "$#" -eq 1 ] && printf '60\\n' ;;
          --muted) printf 'unmuted\\n' ;;
        esac
        exit 0
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let model = FloaterModel(repoRoot: root.path, fmHome: root.path)
        model.refreshVolume()
        try await waitUntil { model.voiceVolume == 60 }

        model.setVoiceVolume(40)
        XCTAssertEqual(model.voiceVolume, 40)
        try await waitUntil {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("--volume 40\n")
        }

    }

    func testStatusIsReadAndOnlyLiveOffersBelongOnTheBubble() {
        let open = Offer.parse(#"{"schema":"fm-desk-offer.v1","id":"ab12cd34","text":"Open the Sound settings","state":"open","after":3}"#)
        XCTAssertEqual(open?.id, "ab12cd34")
        XCTAssertEqual(open?.text, "Open the Sound settings")
        XCTAssertEqual(open?.isActive, true)
        XCTAssertEqual(open?.isActing, false)
        XCTAssertEqual(Offer.parse(#"{"id":"ab12cd34","text":"x","state":"working"}"#)?.isActing, true)
        XCTAssertEqual(Offer.parse(#"{"id":"ab12cd34","text":"x","state":"expired"}"#)?.isActive, false)
        XCTAssertNil(Offer.parse(#"{"schema":"fm-desk-offer.v1","state":"none"}"#))
        XCTAssertNil(Offer.parse("not json"))
        XCTAssertNil(Offer.parse(nil))
    }

    func testAReplyWithoutEyeTextShowsItsSpokenLine() {
        let plain = Reply(id: 1, time: Date(), text: "The fix landed. More on screen.")
        XCTAssertEqual(plain.eye, plain.text)
        XCTAssertEqual(plain.full, plain.text)
        let eye = Reply(id: 2, time: Date(), text: "Spoken.", eye: "Seen. Shall I?", full: nil)
        XCTAssertEqual(eye.full, "Seen. Shall I?")
    }

    private struct Home {
        let root: URL
        let log: URL
    }

    /// A code root whose fm-speak.sh and fm-desk-offer.sh log their arguments.
    private func makeHome(offerState: String) throws -> Home {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("offer-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("calls.log")
        let speak = """
        #!/bin/sh
        printf 'speak %s\\n' "$*" >> '\(log.path)'
        case "$1" in
          --speaking) printf 'quiet\\n' ;;
          --muted) printf 'unmuted\\n' ;;
          --volume) printf '100\\n' ;;
        esac
        exit 0
        """
        let offer = """
        #!/bin/sh
        printf 'offer %s\\n' "$*" >> '\(log.path)'
        case "$1" in
          status) printf '{"schema":"fm-desk-offer.v1","id":"ab12cd34","text":"Open the Sound settings","state":"\(offerState)"}\\n' ;;
          answer) printf 'sent: herdr 1-1\\n' ;;
        esac
        exit 0
        """
        for (name, body) in [("fm-speak.sh", speak), ("fm-desk-offer.sh", offer)] {
            let url = bin.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return Home(root: root, log: log)
    }

    private func calls(_ home: Home) -> String {
        (try? String(contentsOf: home.log, encoding: .utf8)) ?? ""
    }

    @MainActor
    func testDoItSendsTheTapThroughTheOfferScriptAndNotNowDeclines() async throws {
        let home = try makeHome(offerState: "open")
        defer { try? FileManager.default.removeItem(at: home.root) }
        let model = FloaterModel(repoRoot: home.root.path, fmHome: home.root.path)
        model.readOffer()
        try await waitUntil { model.shownOffer?.state == .open }
        XCTAssertTrue(model.bubbleShown, "an open offer keeps the bubble up even with no reply")
        model.doIt()
        try await waitUntil { self.calls(home).contains("offer answer do ab12cd34\n") }
        model.notNow()
        try await waitUntil { self.calls(home).contains("offer answer not-now ab12cd34\n") }
        model.dismissCaption()
        XCTAssertFalse(model.bubbleShown, "a dismissed offer leaves the bubble closed")
    }

    @MainActor
    func testStopStopsTheVoiceAndAsksFirstmateToStopWhileItActs() async throws {
        let home = try makeHome(offerState: "working")
        defer { try? FileManager.default.removeItem(at: home.root) }
        let model = FloaterModel(repoRoot: home.root.path, fmHome: home.root.path)
        model.readOffer()
        try await waitUntil { model.offer?.isActing == true }
        model.stopAll()
        try await waitUntil {
            self.calls(home).contains("speak --stop\n") && self.calls(home).contains("offer answer stop ab12cd34\n")
        }
    }

    @MainActor
    func testWithoutScreenRecordingShowAsksMacOSAndTakesNothing() {
        let model = FloaterModel(repoRoot: "/nonexistent", fmHome: "/nonexistent")
        var asked = 0
        model.onFixScreen = { asked += 1 }
        model.showPressBegan()
        model.showPressBegan()
        model.showPressEnded()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(model.shotCount, 0)
        XCTAssertEqual(model.mode, .idle)
    }


    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("condition never became true")
    }
}

/// The reply bubble stays quiet while the captain is already looking at
/// Starship, and has a switch of its own. The home's scripts are stand-ins:
/// fm-speak.sh lists the replies in history.txt, fm-desk-offer.sh reports an
/// open offer once offer-open exists, and the Starship web page's marker is
/// the file bin/fm-web.py keeps while one of its pages is in front.
extension VoiceVolumeTests {
    private struct Desk {
        let root: URL
        var path: String { root.path }
        var history: URL { root.appendingPathComponent("history.txt") }
        var calls: URL { root.appendingPathComponent("calls.log") }
        var marker: URL { URL(fileURLWithPath: Bubble.webFrontPath(home: path)) }
    }

    private func makeDesk() throws -> Desk {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-\(UUID().uuidString)")
        let home = Desk(root: root)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let speak = """
        #!/bin/sh
        printf 'speak %s\\n' "$*" >> '\(home.calls.path)'
        case "$1" in
          --history) cat '\(home.history.path)' 2>/dev/null ;;
          --caption) printf 'Reply %s for the eye.\\n' "$2" ;;
          --full) printf 'Reply %s in full.\\n' "$2" ;;
          --speaking) printf 'quiet\\n' ;;
          --muted) printf 'unmuted\\n' ;;
          --volume) printf '100\\n' ;;
        esac
        exit 0
        """
        let offer = """
        #!/bin/sh
        if [ -e '\(root.path)/offer-open' ]; then
          printf '{"schema":"fm-desk-offer.v1","id":"ab12cd34","text":"Open the Sound settings","state":"open"}\\n'
        else
          printf '{"schema":"fm-desk-offer.v1","state":"none"}\\n'
        fi
        exit 0
        """
        for (name, body) in [("fm-speak.sh", speak), ("fm-desk-offer.sh", offer)] {
            let url = bin.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return home
    }

    /// A Starship page in front now, as bin/fm-web.py leaves it.
    private func pageInFront(_ home: Desk) throws {
        try FileManager.default.createDirectory(at: home.marker.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: home.marker)
    }

    /// Reply <id> lands in the history, as bin/fm-speak.sh records it.
    private func reply(_ home: Desk, _ id: Int) throws {
        let line = "\(id)\t\(Int(Date().timeIntervalSince1970))\tSpoken line \(id)\n"
        let old = (try? String(contentsOf: home.history, encoding: .utf8)) ?? ""
        try (line + old).write(to: home.history, atomically: true, encoding: .utf8)
        let dir = home.root.appendingPathComponent("state/speak-history")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("\(id)"))
    }

    /// Starts following the replies, once the replies already kept are read,
    /// so the next one counts as new.
    @MainActor
    private func follow(_ model: FloaterModel, _ home: Desk) async throws {
        model.startCaption()
        try await waitUntil { self.called(home, "speak --history\n") }
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private func called(_ home: Desk, _ text: String) -> Bool {
        ((try? String(contentsOf: home.calls, encoding: .utf8)) ?? "").contains(text)
    }

    /// The reported annoyance: a reply popped up beside the floater while the
    /// captain was reading it on the Starship web page.
    @MainActor
    func testAReplyArrivingWhileAStarshipPageIsInFrontNeverShows() async throws {
        let home = try makeDesk()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let model = FloaterModel(repoRoot: home.path, fmHome: home.path)
        try await follow(model, home)
        try pageInFront(home)
        try reply(home, 1)
        try await waitUntil { self.called(home, "speak --caption 1\n") }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(model.lookingAtStarship)
        XCTAssertNil(model.caption, "a reply read on Starship is not written beside the floater")
        XCTAssertFalse(model.bubbleShown)

        try FileManager.default.removeItem(at: home.marker)
        try reply(home, 2)
        try await waitUntil { model.caption?.id == 2 }
        XCTAssertTrue(model.bubbleShown, "off Starship a reply shows as before")
        XCTAssertEqual(model.caption?.eye, "Reply 2 for the eye.")
    }

    /// Looking at Starship while a reply is up takes it away for good.
    @MainActor
    func testAReplyUpWhenTheCaptainTurnsToStarshipGoes() async throws {
        let home = try makeDesk()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let model = FloaterModel(repoRoot: home.path, fmHome: home.path)
        try await follow(model, home)
        try reply(home, 1)
        try await waitUntil { model.caption?.id == 1 }
        try pageInFront(home)
        model.checkScreen()
        try await waitUntil { model.caption == nil }
        try FileManager.default.removeItem(at: home.marker)
        model.checkScreen()
        try await waitUntil { !model.lookingAtStarship }
        XCTAssertNil(model.caption, "a reply the captain turned away from does not come back")
    }

    /// A Do it offer is never lost: it waits behind a quiet bubble and shows
    /// once the captain looks away from Starship.
    @MainActor
    func testAnOfferWaitsWhileOnStarshipAndShowsOnceTheCaptainLooksAway() async throws {
        let home = try makeDesk()
        defer { try? FileManager.default.removeItem(at: home.root) }
        try pageInFront(home)
        try Data().write(to: home.root.appendingPathComponent("offer-open"))
        let model = FloaterModel(repoRoot: home.path, fmHome: home.path)
        model.readOffer()
        try await waitUntil { model.offer?.state == .open }
        XCTAssertTrue(model.lookingAtStarship)
        XCTAssertFalse(model.bubbleShown, "the offer does not pop up on Starship")
        XCTAssertNotNil(model.shownOffer, "but it is still waiting")

        try FileManager.default.removeItem(at: home.marker)
        model.checkScreen()
        try await waitUntil { model.bubbleShown }
        XCTAssertEqual(model.shownOffer?.id, "ab12cd34")
    }

    /// One click turns the whole bubble off or on, and a restarted floater
    /// keeps it that way.
    @MainActor
    func testTheSwitchTurnsTheWholeBubbleOffAndIsKeptAcrossRestarts() async throws {
        let home = try makeDesk()
        defer { try? FileManager.default.removeItem(at: home.root) }
        try Data().write(to: home.root.appendingPathComponent("offer-open"))
        let model = FloaterModel(repoRoot: home.path, fmHome: home.path)
        XCTAssertTrue(model.bubbleOn, "a home that never touched the switch shows the bubble")
        try await follow(model, home)
        try await waitUntil { model.bubbleShown }

        model.toggleBubble()
        XCTAssertFalse(model.bubbleOn)
        XCTAssertFalse(model.bubbleShown, "off means no bubble, even for an offer")
        try reply(home, 1)
        try await waitUntil { self.called(home, "speak --caption 1\n") }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(model.caption, "nor for a new reply")

        let restarted = FloaterModel(repoRoot: home.path, fmHome: home.path)
        XCTAssertFalse(restarted.bubbleOn, "the switch is kept across a restart")
        restarted.toggleBubble()
        XCTAssertTrue(restarted.bubbleOn)
        XCTAssertTrue(FloaterModel(repoRoot: home.path, fmHome: home.path).bubbleOn)
        restarted.readOffer()
        try await waitUntil { restarted.bubbleShown }
    }

    func testOnlyAFreshMarkerSaysAStarshipPageIsInFront() {
        let now = Date()
        XCTAssertTrue(Bubble.webInFront(modified: now.addingTimeInterval(-3), now: now))
        XCTAssertFalse(Bubble.webInFront(modified: now.addingTimeInterval(-20), now: now),
                       "a browser that went away while focused does not silence the bubble")
        XCTAssertFalse(Bubble.webInFront(modified: nil, now: now))
        XCTAssertTrue(Bubble.allowed(on: true, lookingAtStarship: false))
        XCTAssertFalse(Bubble.allowed(on: true, lookingAtStarship: true))
        XCTAssertFalse(Bubble.allowed(on: false, lookingAtStarship: false))
    }
}
