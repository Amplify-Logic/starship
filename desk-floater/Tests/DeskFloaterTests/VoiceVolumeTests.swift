import AppKit
import SwiftUI
import XCTest
@testable import DeskFloater

/// The speaker button's secondary click and the voice-volume control it opens.
final class VoiceVolumeTests: XCTestCase {
    private func click(_ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func clicks(_ event: NSEvent) -> [String] {
        var fired: [String] = []
        let view = SpeakerClickView()
        view.onMute = { fired.append("mute") }
        view.onVolume = { fired.append("volume") }
        if event.type == .rightMouseDown {
            view.rightMouseDown(with: event)
        } else {
            view.mouseDown(with: event)
        }
        return fired
    }

    func testPlainClickMutesAndSecondaryClicksOpenTheVolumeControl() {
        XCTAssertEqual(clicks(click(.leftMouseDown)), ["mute"])
        XCTAssertEqual(clicks(click(.rightMouseDown)), ["volume"])
        XCTAssertEqual(clicks(click(.leftMouseDown, .control)), ["volume"],
                       "a Control-click must open the volume control and must not also mute")
        XCTAssertEqual(clicks(click(.rightMouseDown, .control)), ["volume"])
        XCTAssertEqual(clicks(click(.leftMouseDown, .shift)), ["mute"])
    }

    /// The catcher sits over a SwiftUI button, as the speaker button does in the
    /// floater, and the hosting view must hand it the click rather than keep it.
    @MainActor
    func testTheHostingViewDeliversTheSpeakerButtonsClicksToTheCatcher() {
        let view = Button("speaker") {}
            .frame(width: 20, height: 20)
            .overlay { SpeakerClickCatcher(help: "Mute voice", onMute: {}, onVolume: {}) }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(hosting.hitTest(NSPoint(x: 10, y: 10)) is SpeakerClickView,
                      "a click on the speaker button must reach the click catcher")
    }

    func testTheSpeakerButtonTakesTheFirstClickOfAnInactivePanel() {
        XCTAssertTrue(SpeakerClickView().acceptsFirstMouse(for: click(.rightMouseDown)))
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

    /// The control reads the kept level when it opens and keeps a new one
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
        XCTAssertFalse(model.showingVolume)
        model.toggleVolume()
        XCTAssertTrue(model.showingVolume)
        try await waitUntil { model.voiceVolume == 60 }

        model.setVoiceVolume(40)
        XCTAssertEqual(model.voiceVolume, 40)
        try await waitUntil {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("--volume 40\n")
        }

        model.toggleVolume()
        XCTAssertFalse(model.showingVolume)
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
