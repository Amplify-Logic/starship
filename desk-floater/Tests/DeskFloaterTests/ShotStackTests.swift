import XCTest
@testable import DeskFloater

final class ShotStackTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    func testTalkShotsTalkAgainGoAsOneMessage() {
        var stack = ShotStack()
        stack.talkEnded(at: at(0))
        stack.shotStarted(at: at(0.5))
        stack.shotFinished("/shots/a.png", at: at(0.6))
        stack.shotStarted(at: at(1))
        stack.shotFinished("/shots/b.png", at: at(1.1))
        XCTAssertTrue(stack.hold("Why is this red"))

        stack.talkEnded(at: at(3))
        XCTAssertFalse(stack.ready(at: at(4.2)), "the second talk restarts the wait")
        XCTAssertTrue(stack.hold("and this one too"))
        XCTAssertFalse(stack.ready(at: at(5.9)))
        XCTAssertTrue(stack.ready(at: at(6)))

        let message = stack.take()
        XCTAssertEqual(message.text, "Why is this red and this one too")
        XCTAssertEqual(message.images, ["/shots/a.png", "/shots/b.png"])
        XCTAssertTrue(stack.isEmpty)
    }

    func testTalkWithNothingStackedGoesAtOnce() {
        var stack = ShotStack()
        stack.talkEnded(at: at(0))
        XCTAssertFalse(stack.hold("Just words"))
        XCTAssertTrue(stack.isEmpty)
    }

    func testCaptureStillBeingWrittenHoldsTheStack() {
        var stack = ShotStack()
        stack.shotStarted(at: at(0))
        XCTAssertTrue(stack.hold("Look at this"))
        XCTAssertFalse(stack.ready(at: at(10)))
        stack.shotFinished("/shots/a.png", at: at(10))
        XCTAssertFalse(stack.ready(at: at(12.9)))
        XCTAssertTrue(stack.ready(at: at(13)))
        XCTAssertEqual(stack.take().images, ["/shots/a.png"])
    }

    func testFailedCaptureStillSendsTheHeldWords() {
        var stack = ShotStack()
        stack.shotStarted(at: at(0))
        XCTAssertTrue(stack.hold("Look at this"))
        stack.shotFinished(nil, at: at(1))
        XCTAssertEqual(stack.count, 0)
        XCTAssertTrue(stack.ready(at: at(3)))
        let message = stack.take()
        XCTAssertEqual(message.text, "Look at this")
        XCTAssertEqual(message.images, [])
    }
}
