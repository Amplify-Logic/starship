import AVFoundation
import XCTest
@testable import DeskFloater

final class CaptureConverterTests: XCTestCase {
    /// The shape voice processing delivers on a MacBook Pro: nine
    /// deinterleaved Float32 channels at 44.1 kHz.
    private let voiceProcessed = AVAudioFormat(
        standardFormatWithSampleRate: 44100,
        channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 9)!)

    /// Runs one second of input through the converter in capture-sized buffers,
    /// with <voice> on the first channel and <other> on every other channel.
    private func convertOneSecond(voice: Float, other: Float) throws -> [Int16] {
        let converter = try CaptureConverter(from: voiceProcessed)
        var samples: [Int16] = []
        var frame = 0
        while frame < 44100 {
            let count = min(4096, 44100 - frame)
            let buffer = AVAudioPCMBuffer(pcmFormat: voiceProcessed, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count {
                let wave = sin(2 * Float.pi * 440 * Float(frame + i) / 44100)
                buffer.floatChannelData![0][i] = voice * wave
                for channel in 1..<9 {
                    buffer.floatChannelData![channel][i] = other * wave
                }
            }
            if let out = converter.convert(buffer) {
                XCTAssertEqual(out.format, VoiceCapture.fileFormat)
                samples += UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength))
            }
            frame += count
        }
        return samples
    }

    private func rms(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    func testOneSecondBecomesOneSecondOfSixteenKilohertzMono() throws {
        let samples = try convertOneSecond(voice: 0.5, other: 0)
        XCTAssertEqual(Double(samples.count), 16000, accuracy: 400)
        XCTAssertGreaterThan(rms(samples), 5000, "the voice channel reaches the file")
    }

    func testOnlyTheProcessedVoiceChannelIsKept() throws {
        let samples = try convertOneSecond(voice: 0, other: 0.5)
        XCTAssertLessThan(rms(samples), 50, "the other channels never reach the file")
    }

    func testAFormatWithoutFloatSamplesIsRefused() {
        let integer = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true)!
        XCTAssertThrowsError(try CaptureConverter(from: integer))
    }
}
