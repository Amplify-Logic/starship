import XCTest
@testable import DeskFloater

final class TalkKeyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// Holding Right Option and clicking where a menu pops up: the voice note
    /// lost on 10 Oct 2026.
    func testClickMidRecordingKeepsRecordingAndDeliversOnRelease() {
        var key = TalkKey()
        XCTAssertEqual(key.update(down: true, at: at(0)), .begin)
        XCTAssertNil(key.chord(at: at(4)), "a click while talking is not a shortcut")
        XCTAssertTrue(key.isDown, "the hold carries on")
        XCTAssertNil(key.chord(at: at(4.2)), "nor is a second click")
        XCTAssertEqual(key.update(down: false, at: at(30)), .deliver, "releasing the key sends the message")
    }

    func testQuickOptionLetterAtTheStartIsAShortcut() {
        var key = TalkKey()
        XCTAssertEqual(key.update(down: true, at: at(0)), .begin)
        XCTAssertEqual(key.chord(at: at(0.1)), .drop, "Option-letter types a character")
        XCTAssertFalse(key.isDown)
        XCTAssertNil(key.chord(at: at(0.15)), "the rest of the shortcut changes nothing")
        XCTAssertNil(key.update(down: false, at: at(0.2)), "and its release sends nothing")
    }

    func testLongRecordingIsNeverDroppedByAKeyOrClick() {
        var key = TalkKey()
        XCTAssertEqual(key.update(down: true, at: at(0)), .begin)
        for second in stride(from: 1.0, through: 600, by: 0.7) {
            XCTAssertNil(key.chord(at: at(second)), "a key or click \(second)s into the hold")
        }
        XCTAssertEqual(key.update(down: false, at: at(601)), .deliver)
    }

    func testEachHoldGetsItsOwnShortcutMoment() {
        var key = TalkKey()
        XCTAssertEqual(key.update(down: true, at: at(0)), .begin)
        XCTAssertEqual(key.update(down: false, at: at(5)), .deliver)
        XCTAssertEqual(key.update(down: true, at: at(10)), .begin)
        XCTAssertEqual(key.chord(at: at(10.1)), .drop, "measured from the new press, not the first")
    }

    func testKeysAndClicksWithRightOptionUpChangeNothing() {
        var key = TalkKey()
        XCTAssertNil(key.chord(at: at(0)))
        XCTAssertNil(key.update(down: false, at: at(1)), "a release with no press sends nothing")
        XCTAssertEqual(key.update(down: true, at: at(2)), .begin)
        XCTAssertNil(key.update(down: true, at: at(2.5)), "a repeated down is the same hold")
        XCTAssertNil(key.chord(at: at(2.6)), "and keeps its original start")
    }
}
