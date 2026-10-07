import AVFoundation
import XCTest
@testable import DeskFloater

final class RecordingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-floater-recording-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func wav(seconds: Double) throws -> URL {
        let url = dir.appendingPathComponent("\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = AVAudioFrameCount(seconds * 16000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    func testEmptyTranscriptsAreKeptOnlyWhenLongEnoughToHoldWords() {
        XCTAssertFalse(Recording.keep(failed: false, duration: 1.2), "a stray press is not kept")
        XCTAssertTrue(Recording.keep(failed: false, duration: 2.5))
        XCTAssertTrue(Recording.keep(failed: false, duration: 600))
    }

    func testFailedTranscriptionsKeepEvenAShortAnswer() {
        XCTAssertTrue(Recording.keep(failed: true, duration: 1), "a one-word answer is kept")
        XCTAssertFalse(Recording.keep(failed: true, duration: 0.2))
    }

    func testRetriesFollowTheScheduleThenStop() {
        XCTAssertEqual(Recording.retryDelay(afterAttempts: 1), Recording.retryDelays[0])
        XCTAssertEqual(Recording.retryDelay(afterAttempts: Recording.retryDelays.count),
                       Recording.retryDelays.last)
        XCTAssertNil(Recording.retryDelay(afterAttempts: Recording.retryDelays.count + 1))
        XCTAssertNil(Recording.retryDelay(afterAttempts: 0))
        XCTAssertGreaterThanOrEqual(Recording.retryDelays.count, 3, "a few automatic retries")
    }

    func testDurationOfAFinishedRecording() throws {
        let url = try wav(seconds: 3)
        XCTAssertEqual(Recording.duration(of: url), 3, accuracy: 0.01)
    }

    func testDurationOfATenMinuteRecordingHasNoCap() throws {
        let url = try wav(seconds: 600)
        XCTAssertEqual(Recording.duration(of: url), 600, accuracy: 0.01)
        XCTAssertTrue(Recording.keep(failed: false, duration: Recording.duration(of: url)))
    }

    func testDurationOfAFileLeftUnfinishedComesFromItsSize() throws {
        let url = dir.appendingPathComponent("unfinished.wav")
        try Data(count: 44 + 32_000 * 4).write(to: url)
        XCTAssertEqual(Recording.duration(of: url), 4, accuracy: 0.01)
        XCTAssertEqual(Recording.duration(of: dir.appendingPathComponent("missing.wav")), 0)
    }

    /// A capture cut off mid-recording has a well-formed header whose data
    /// length was never filled in; it is measured by its size, not as empty.
    func testDurationOfAFileWhoseHeaderReportsNoLengthComesFromItsSize() throws {
        let url = dir.appendingPathComponent("cut-off.wav")
        var header = Data()
        func append(_ text: String) { header.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        append("RIFF"); append32(36); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(16000); append32(32_000); append16(2); append16(16)
        append("data"); append32(0)
        try (header + Data(count: 32_000 * 4)).write(to: url)
        XCTAssertEqual(Recording.duration(of: url), 4, accuracy: 0.01)
        XCTAssertTrue(Recording.keep(failed: true, duration: Recording.duration(of: url)))
    }

    func testTheFileNameCarriesThePurpose() {
        XCTAssertEqual(Recording.purpose(ofFileName: Recording.fileName(purpose: "dictate")), "dictate")
        XCTAssertEqual(Recording.purpose(ofFileName: Recording.fileName(purpose: "firstmate")), "firstmate")
        XCTAssertEqual(Recording.purpose(ofFileName: "anything-else.wav"), "firstmate")
    }

    func testAMailboxDeliveryReadsAsSavedForFirstmate() {
        XCTAssertEqual(SendOutcome.status("sent: herdr w7:p3\n"), "Sent")
        XCTAssertEqual(SendOutcome.status("sent-unconfirmed: herdr w7:p3 (pending)\n"), "Sent, unconfirmed")
        XCTAssertEqual(SendOutcome.status("mailbox: /home/state/desk-voice/inbox/x.json\n"), "Saved for Firstmate")
        XCTAssertNil(SendOutcome.status(nil), "a failed send delivered nothing")
    }

    func testRetryLinesAreRead() {
        XCTAssertEqual(RetryResult.parse("delivered\t/u/a.wav\tsent: herdr w7:p3\n"), .delivered(status: "Sent"))
        XCTAssertEqual(RetryResult.parse("delivered\t/u/a.wav\tmailbox: /i/x.json\n"),
                       .delivered(status: "Saved for Firstmate"))
        XCTAssertEqual(RetryResult.parse("unsent\t/u/a.wav\t3\tno speech heard\n"), .unsent(attempts: 3))
        XCTAssertEqual(RetryResult.parse("busy\t/u/a.wav\n"), .busy)
        XCTAssertEqual(RetryResult.parse("gone\t/u/a.wav\n"), .gone)
        XCTAssertNil(RetryResult.parse(""))
        XCTAssertNil(RetryResult.parse("unsent\t/u/a.wav\tmany\n"))
    }

    /// At launch the floater saves a recording a stopped floater left behind,
    /// through bin/fm-desk-voice.sh keep (here a stand-in that records what it
    /// was asked), drops one too short to hold words, and resumes the retries
    /// of saved talk-to-Firstmate recordings only: a dictation waits for a
    /// manual retry.
    @MainActor
    func testLaunchSavesARecordingLeftBehindAndShowsTheRetry() async throws {
        let root = dir.appendingPathComponent("home")
        let bin = root.appendingPathComponent("bin")
        let recording = root.appendingPathComponent("state/desk-voice/recording")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("desk.log")
        let stub = bin.appendingPathComponent("fm-desk-voice.sh")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        case "$1" in
          keep) printf '/saved/one.wav\\n' ;;
          recordings)
            printf '/saved/one.wav\\tdictate\\t1\\tstamp\\tthe floater stopped\\n'
            printf '/saved/two.wav\\tfirstmate\\t1\\tstamp\\ttranscription failed\\n'
            ;;
        esac
        exit 0
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let long = recording.appendingPathComponent(Recording.fileName(purpose: "dictate"))
        try FileManager.default.moveItem(at: try wav(seconds: 3), to: long)
        let short = recording.appendingPathComponent(Recording.fileName(purpose: "firstmate"))
        try FileManager.default.moveItem(at: try wav(seconds: 0.1), to: short)
        let earlier = Date().addingTimeInterval(-60)
        for url in [long, short] {
            try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: url.path)
        }
        let live = recording.appendingPathComponent(Recording.fileName(purpose: "firstmate"))
        try FileManager.default.moveItem(at: try wav(seconds: 3), to: live)

        let model = FloaterModel(repoRoot: root.path, fmHome: root.path)
        model.recoverRecordings()
        try await waitUntil { model.status == FloaterModel.savedRetrying }

        let calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(calls.contains("keep --purpose dictate --reason the floater stopped before it was sent -- \(long.path)\n"),
                      calls)
        XCTAssertFalse(calls.contains(short.path), "a stray press is dropped, not saved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: short.path))
        XCTAssertFalse(calls.contains(live.path), "a capture still being written is left alone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        XCTAssertTrue(calls.contains("recordings\n"))
        XCTAssertEqual(Array(model.retrying.keys), ["/saved/two.wav"], "a saved dictation is not retried by itself")
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
