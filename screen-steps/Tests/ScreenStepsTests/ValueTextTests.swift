import AppKit
import XCTest
@testable import ScreenSteps

final class ValueTextTests: XCTestCase {
    private let values = [
        "com.example.harbourlogbook",
        "com.example-app.harbourlogbook.widget",
        "HC-2026-IOS-0001",
        "English (U.S.)",
        "café 👩‍💻 ok",
    ]

    /// Every place the text system may wrap `text`.
    private func breaks(_ text: String) -> [Int] {
        let shown = NSAttributedString(string: text)
        let length = shown.length
        return (1...length).map { shown.lineBreak(before: $0, within: NSRange(location: 0, length: length)) }
    }

    func testShownValueIsExactlyTheCopiedValue() {
        for value in values {
            let shown = ValueText.wrappable(value).replacingOccurrences(of: "\u{200B}", with: "")
            XCTAssertEqual(shown, value, "no character is added, dropped or changed")
        }
    }

    /// A bundle ID has no break opportunity of its own, so it used to wrap as
    /// "com.example.happinesscom-" / "pass" with an invented hyphen.
    func testLongValueCanWrapAfterEveryCharacter() {
        let value = "com.example.harbourlogbook"
        XCTAssertEqual(Set(breaks(value)), [0], "the bare value cannot wrap anywhere")

        let shown = ValueText.wrappable(value)
        var afterEachCharacter: Set<Int> = []
        var offset = 0
        for character in shown {
            offset += character.utf16.count
            if character == "\u{200B}" {
                afterEachCharacter.insert(offset)
            }
        }
        XCTAssertEqual(afterEachCharacter.count, value.count - 1)
        XCTAssertTrue(afterEachCharacter.isSubset(of: Set(breaks(shown))),
                      "the shown value can wrap after any character")
    }
}
