import AppKit
import XCTest
@testable import DeskFloater

final class TapKeyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let limit: TimeInterval = 0.5
    // Right Shift's flagsChanged: the shift flag plus the right-hand device bit.
    private let rightShiftDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x04)
    private let leftShiftDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x02)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// Presses Right Shift at `down` and releases it at `up`; returns the tap
    /// time when the release completed a tap.
    private func tap(_ key: inout TapKey, down: TimeInterval, up: TimeInterval) -> Date? {
        XCTAssertFalse(key.update(keyCode: 60, flags: rightShiftDown, at: at(down), allowed: [], limit: limit))
        return key.update(keyCode: 60, flags: [], at: at(up), allowed: [], limit: limit) ? at(up) : nil
    }

    func testDeliberateTapAwayFromTypingTakesAShot() {
        var key = TapKey.rightShift
        key.keyPressed(at: at(0))
        guard let tapped = tap(&key, down: 2, up: 2.1) else {
            return XCTFail("a lone tap well after typing is a tap")
        }
        key.keyPressed(at: at(3))
        XCTAssertTrue(key.takeSettled(tap: tapped), "typing after the settle window leaves the shot alone")
    }

    func testCapitalLetterIsNotATap() {
        var key = TapKey.rightShift
        XCTAssertFalse(key.update(keyCode: 60, flags: rightShiftDown, at: at(5), allowed: [], limit: limit))
        key.keyPressed(at: at(5.05))
        XCTAssertFalse(key.update(keyCode: 60, flags: [], at: at(5.12), allowed: [], limit: limit))
    }

    /// "…How could this shape" then Right Shift brushed twice, 140 ms apart,
    /// before "?" and Return: the shots of 6 Oct 2026, 17:51.
    func testShiftBrushedMidSentenceIsNotATap() {
        var key = TapKey.rightShift
        for (i, _) in "How could this shape".enumerated() {
            key.keyPressed(at: at(Double(i) * 0.15))
        }
        let lastKey = Double("How could this shape".count - 1) * 0.15
        XCTAssertNil(tap(&key, down: lastKey + 0.3, up: lastKey + 0.36), "a brush right after typing")
        XCTAssertNil(tap(&key, down: lastKey + 0.45, up: lastKey + 0.5), "and a second one just after it")
    }

    /// "?" typed with Right Shift at the end of a sentence in a terminal: the
    /// shot of 6 Oct 2026, 20:25:58 UTC.
    func testShiftedPunctuationIsNotATap() {
        var key = TapKey.rightShift
        // After a long pause: the "/" pressed while Shift is down makes it a shortcut.
        key.keyPressed(at: at(0))
        XCTAssertFalse(key.update(keyCode: 60, flags: rightShiftDown, at: at(5), allowed: [], limit: limit))
        key.keyPressed(at: at(5.05))
        XCTAssertFalse(key.update(keyCode: 60, flags: [], at: at(5.1), allowed: [], limit: limit),
                       "Shift held with a key is a shortcut, not a tap")
        XCTAssertFalse(key.takeSettled(tap: at(5.1)))
        // Right after typing, with the "/" press itself never reaching the floater.
        key.keyPressed(at: at(10))
        XCTAssertNil(tap(&key, down: 10.2, up: 10.3), "a Shift pressed straight after typing is typing")
        XCTAssertFalse(key.takeSettled(tap: at(10.3)))
    }

    func testTapThatTypingResumesAfterIsDropped() {
        var key = TapKey.rightShift
        // A pause long enough to pass the quiet window, then a brush and "?".
        key.keyPressed(at: at(0))
        guard let tapped = tap(&key, down: 3, up: 3.05) else {
            return XCTFail("the brush itself reads as a tap")
        }
        key.keyPressed(at: at(3.2))
        XCTAssertFalse(key.takeSettled(tap: tapped), "a key straight after the tap means it was typing")
    }

    func testLaterTapReplacesAnUnsettledOne() {
        var key = TapKey.rightShift
        guard let first = tap(&key, down: 0, up: 0.05),
              let second = tap(&key, down: 0.15, up: 0.2) else {
            return XCTFail("both are taps")
        }
        XCTAssertFalse(key.takeSettled(tap: first))
        XCTAssertTrue(key.takeSettled(tap: second))
        XCTAssertFalse(key.takeSettled(tap: second), "a tap stands once")
    }

    func testHeldShiftAndOtherModifiersAreNotTaps() {
        var key = TapKey.rightShift
        XCTAssertNil(tap(&key, down: 0, up: 0.6), "held past the tap limit")
        let withLeft = NSEvent.ModifierFlags(rawValue: rightShiftDown.rawValue | leftShiftDown.rawValue)
        XCTAssertFalse(key.update(keyCode: 60, flags: withLeft, at: at(2), allowed: [], limit: limit))
        XCTAssertTrue(key.update(keyCode: 60, flags: [], at: at(2.1), allowed: [], limit: limit),
                      "the left Shift already down is Shift, not another modifier")
        let withCommand = rightShiftDown.union(.command)
        XCTAssertFalse(key.update(keyCode: 60, flags: withCommand, at: at(4), allowed: [], limit: limit))
        XCTAssertFalse(key.update(keyCode: 60, flags: [], at: at(4.1), allowed: [], limit: limit))
        XCTAssertFalse(key.update(keyCode: 60, flags: rightShiftDown.union(.option), at: at(6), allowed: .option, limit: limit))
        XCTAssertTrue(key.update(keyCode: 60, flags: .option, at: at(6.1), allowed: .option, limit: limit),
                      "Right Option held for talk is allowed")
    }

    func testClickWhileDownIsAShortcutButNotTyping() {
        var key = TapKey.rightShift
        XCTAssertFalse(key.update(keyCode: 60, flags: rightShiftDown, at: at(0), allowed: [], limit: limit))
        key.chord()
        XCTAssertFalse(key.update(keyCode: 60, flags: [], at: at(0.1), allowed: [], limit: limit))
        XCTAssertNotNil(tap(&key, down: 0.2, up: 0.3), "a click is not typing, so the next tap stands")
    }

    func testDictationKeyKeepsItsPlainTap() {
        var key = TapKey.rightCommand
        let rightCommandDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10)
        key.keyPressed(at: at(0))
        XCTAssertFalse(key.update(keyCode: 54, flags: rightCommandDown, at: at(0.1), allowed: [], limit: limit))
        XCTAssertTrue(key.update(keyCode: 54, flags: [], at: at(0.2), allowed: [], limit: limit))
    }
}
