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
        XCTAssertEqual(menu?.items.map(\.title), ["Voice volume", "Mute voice"])
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
