import AVFoundation
import Foundation

/// A recording is kept until its words have reached where they were going.
/// One that cannot be transcribed, comes back with no words although it is
/// long enough to hold some, or cannot be delivered is handed to
/// `bin/fm-desk-voice.sh keep`, which saves it in the home's private
/// `state/desk-voice/unsent/`. A talk-to-Firstmate recording is tried again on
/// `retryDelays`; a dictation waits for a manual retry.
enum Recording {
    /// A recording this long that comes back with no words is kept: words may
    /// be in it that were missed. A shorter one is a stray press.
    static let keepEmptyAfter: TimeInterval = 2
    /// A recording this long whose transcription failed is kept: even a
    /// one-word answer matters.
    static let keepFailedAfter: TimeInterval = 0.5
    /// Seconds before each automatic retry of a saved recording.
    static let retryDelays: [TimeInterval] = [20, 60, 300]
    /// A retry that finds another retry running looks again after this long,
    /// without counting as an attempt.
    static let busyDelay: TimeInterval = 30
    /// The capture format's bytes per second (16 kHz, 16-bit, mono), for a file
    /// whose header was never finished.
    private static let bytesPerSecond: Double = 32_000

    /// Whether a recording that produced no words is worth keeping.
    static func keep(failed: Bool, duration: TimeInterval) -> Bool {
        duration >= (failed ? keepFailedAfter : keepEmptyAfter)
    }

    /// The wait before the next retry of a recording that has had `attempts`
    /// attempts so far, or nil when the automatic retries are used up.
    static func retryDelay(afterAttempts attempts: Int) -> TimeInterval? {
        let index = attempts - 1
        return retryDelays.indices.contains(index) ? retryDelays[index] : nil
    }

    /// How long a recording lasts. A file left unfinished by a floater that
    /// stopped mid-capture, whose header is unreadable or reports no length,
    /// is measured by its size.
    static func duration(of url: URL) -> TimeInterval {
        if let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0, file.length > 0 {
            return Double(file.length) / file.processingFormat.sampleRate
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .doubleValue ?? 0
        return max(0, size - 44) / bytesPerSecond
    }

    /// The name a capture is recorded under, carrying its purpose so a
    /// recording left behind by a stopped floater is saved with the right one.
    static func fileName(purpose: String, id: UUID = UUID()) -> String {
        "\(id.uuidString)-\(purpose).wav"
    }

    /// The purpose a recording's name carries: "firstmate" or "dictate".
    static func purpose(ofFileName name: String) -> String {
        name.hasSuffix("-dictate.wav") ? "dictate" : "firstmate"
    }
}

/// What `bin/fm-desk-voice.sh send` printed, as the status line words it, or
/// nil when the send itself failed and nothing was delivered.
enum SendOutcome {
    static let savedForFirstmate = "Saved for Firstmate"

    static func status(_ out: String?) -> String? {
        guard let out else { return nil }
        if out.hasPrefix("sent:") { return "Sent" }
        if out.hasPrefix("sent-unconfirmed:") { return "Sent, unconfirmed" }
        return savedForFirstmate
    }
}

/// One line of `bin/fm-desk-voice.sh retry`.
enum RetryResult: Equatable {
    /// Talk to Firstmate: the words went, with this status line.
    case delivered(status: String)
    /// Still not delivered after this many attempts; kept.
    case unsent(attempts: Int)
    /// Another retry holds the lock.
    case busy
    /// Already delivered or removed.
    case gone

    static func parse(_ line: String) -> RetryResult? {
        let cols = line.trimmingCharacters(in: .newlines)
            .split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard cols.count >= 2 else { return nil }
        switch cols[0] {
        case "delivered" where cols.count >= 3:
            return .delivered(status: SendOutcome.status(cols[2]) ?? SendOutcome.savedForFirstmate)
        case "unsent" where cols.count >= 3:
            return Int(cols[2]).map { .unsent(attempts: $0) }
        case "busy":
            return .busy
        case "gone":
            return .gone
        default:
            return nil
        }
    }
}
