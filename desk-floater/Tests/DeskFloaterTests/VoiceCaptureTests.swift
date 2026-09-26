import AVFoundation
import XCTest
@testable import DeskFloater

/// Stands in for the Mac's default audio devices.
private final class FakeSystem {
    var input: AudioDeviceID = 1
    var output: AudioDeviceID = 2
}

/// Stands in for the microphone: the test feeds audio through the tap by hand.
private final class FakeEngine: CaptureEngine {
    let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    private let system: FakeSystem
    var onChange: (() -> Void)?
    var failNextStart = false
    private(set) var running = false
    private var tap: ((AVAudioPCMBuffer) -> Void)?

    init(system: FakeSystem) {
        self.system = system
    }

    var setup: AudioSetup {
        AudioSetup(format: inputFormat, input: system.input, output: system.output)
    }

    func installTap(_ block: @escaping (AVAudioPCMBuffer) -> Void) {
        tap = block
    }

    func removeTap() {
        tap = nil
    }

    func start() throws {
        if failNextStart {
            failNextStart = false
            throw NSError(domain: "FakeEngine", code: 1)
        }
        running = true
    }

    func stop() {
        running = false
    }

    /// The configuration-change notification, whether or not anything the
    /// engine was built for actually changed.
    func reportChange() {
        onChange?()
    }

    /// Delivers `seconds` of a spoken-level tone in capture-sized buffers,
    /// as the microphone would while the engine runs.
    func speak(_ seconds: Double) {
        let total = Int(seconds * inputFormat.sampleRate)
        var frame = 0
        while frame < total {
            let count = min(4800, total - frame)
            let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count {
                buffer.floatChannelData![0][i] = 0.5 * sin(2 * Float.pi * 220 * Float(frame + i) / 48000)
            }
            if running {
                tap?(buffer)
            }
            frame += count
        }
    }
}

final class VoiceCaptureTests: XCTestCase {
    private let system = FakeSystem()
    private var built: [FakeEngine] = []
    private var files: [URL] = []

    override func tearDown() {
        for url in files {
            try? FileManager.default.removeItem(at: url)
        }
        super.tearDown()
    }

    private func makeCapture() -> VoiceCapture {
        VoiceCapture(makeEngine: { [unowned self] in
            let engine = FakeEngine(system: system)
            built.append(engine)
            return engine
        })
    }

    private func newFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-capture-test-\(UUID().uuidString).wav")
        files.append(url)
        return url
    }

    private func seconds(in url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    func testEveryCaptureReusesTheEngineBuiltBeforeTheFirstPress() throws {
        let capture = makeCapture()
        try capture.warm()
        XCTAssertEqual(built.count, 1, "the slow voice-processing setup happens before any press")
        for _ in 0..<3 {
            let url = newFile()
            try capture.start(writingTo: url)
            built.last!.speak(1.5)
            capture.stop()
            XCTAssertEqual(try seconds(in: url), 1.5, accuracy: 0.05, "every word from the press on is kept")
        }
        XCTAssertEqual(built.count, 1, "no press waits for the engine to be built again")
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func testADeviceChangeBetweenCapturesRebuildsTheEngineBeforeTheNextPress() throws {
        let capture = makeCapture()
        try capture.warm()
        system.input = 3
        built[0].reportChange()
        drainMainQueue()
        XCTAssertEqual(built.count, 2, "the engine is rebuilt while the captain is not talking")
        built[1].reportChange()
        drainMainQueue()
        XCTAssertEqual(built.count, 2, "the rebuilt engine's own notification leaves it alone")

        let url = newFile()
        try capture.start(writingTo: url)
        XCTAssertEqual(built.count, 2, "the next press does not wait for a rebuild")
        built[1].speak(1.0)
        capture.stop()
        XCTAssertEqual(try seconds(in: url), 1.0, accuracy: 0.05)
    }

    func testANotificationThatChangesNothingKeepsTheEngine() throws {
        let capture = makeCapture()
        try capture.warm()
        built[0].reportChange()
        drainMainQueue()
        try capture.start(writingTo: newFile())
        capture.stop()
        XCTAssertEqual(built.count, 1, "an unchanged setup is never rebuilt")
    }

    func testADeviceChangeDuringACaptureLeavesTheRecordingAlone() throws {
        let capture = makeCapture()
        let url = newFile()
        try capture.start(writingTo: url)
        built[0].speak(0.5)
        system.output = 4
        built[0].reportChange()
        drainMainQueue()
        XCTAssertEqual(built.count, 1, "the running capture keeps its engine")
        built[0].speak(0.5)
        capture.stop()
        XCTAssertEqual(try seconds(in: url), 1.0, accuracy: 0.05)

        try capture.start(writingTo: newFile())
        XCTAssertEqual(built.count, 2, "the next capture rebuilds the changed engine")
        capture.stop()
    }

    func testAudioArrivingAfterReleaseIsKeptUntilTheTailEnds() throws {
        let capture = makeCapture()
        let url = newFile()
        try capture.start(writingTo: url)
        let engine = built.last!
        engine.speak(1.0)
        let closed = expectation(description: "file closed")
        capture.finish(after: 0.3) {
            closed.fulfill()
        }
        // The last syllable, still on its way in after the key came up.
        engine.speak(0.2)
        wait(for: [closed], timeout: 2)
        engine.speak(0.5)
        XCTAssertEqual(try seconds(in: url), 1.2, accuracy: 0.05,
                       "audio up to the end of the tail is kept, nothing after it")
    }

    func testAnEngineThatStopsWorkingIsRebuiltForTheCapture() throws {
        let capture = makeCapture()
        try capture.warm()
        built[0].failNextStart = true
        let first = newFile()
        try capture.start(writingTo: first)
        XCTAssertEqual(built.count, 2, "a failed start builds a fresh engine and records")
        built[1].speak(0.5)
        capture.stop()
        XCTAssertEqual(try seconds(in: first), 0.5, accuracy: 0.05)

        system.input = 3
        let second = newFile()
        try capture.start(writingTo: second)
        XCTAssertEqual(built.count, 3, "an engine whose devices changed is rebuilt")
        built[2].speak(0.5)
        capture.stop()
        XCTAssertEqual(try seconds(in: second), 0.5, accuracy: 0.05)
    }
}
