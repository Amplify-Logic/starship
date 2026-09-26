import AVFoundation
import Foundation

/// Records the microphone to a 16 kHz mono 16-bit WAV for transcription, with
/// macOS voice processing (echo cancellation) switched on.
///
/// Firstmate's replies are spoken out of this Mac's own speakers, often while
/// the captain is talking back. A plain recorder hears them through the
/// microphone and the transcript then carries Firstmate's words as if the
/// captain had said them. Voice processing removes this Mac's playback from the
/// captured signal, including audio from other processes such as the speaker
/// bin/fm-speak.sh starts, so the reply keeps playing and stays out of the
/// message.
///
/// macOS always lowers other audio while voice processing captures; there is no
/// setting that turns that off. The lowering is set to its minimum and to apply
/// only while speech is detected, so a reply dips briefly while the captain
/// talks and is never paused or stopped.
final class VoiceCapture {
    /// The format of the file handed to transcription.
    static let fileFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    let url: URL
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: CaptureConverter?

    init(url: URL) {
        self.url = url
    }

    func start() throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: true, duckingLevel: .min)
        let format = input.outputFormat(forBus: 0)
        let converter = try CaptureConverter(from: format)
        let file = try AVAudioFile(
            forWriting: url, settings: Self.fileFormat.settings,
            commonFormat: .pcmFormatInt16, interleaved: true)
        lock.withLock {
            self.converter = converter
            self.file = file
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.write(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    /// Stops capturing and closes the file; safe to call more than once.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock {
            file = nil
            converter = nil
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let file, let converter, let out = converter.convert(buffer) else { return }
            try? file.write(from: out)
        }
    }
}

/// Turns the voice-processed input into the transcription format. Voice
/// processing can deliver several channels (nine on a MacBook Pro); the first
/// one carries the processed voice, so it alone is kept, then resampled.
final class CaptureConverter {
    let input: AVAudioFormat
    private let mono: AVAudioFormat
    private let converter: AVAudioConverter

    struct Unsupported: Error {}

    init(from input: AVAudioFormat) throws {
        guard input.commonFormat == .pcmFormatFloat32, input.channelCount >= 1,
              let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate,
                channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: VoiceCapture.fileFormat)
        else {
            throw Unsupported()
        }
        self.input = input
        self.mono = mono
        self.converter = converter
    }

    /// Converts one captured buffer; nil when nothing came out of it.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, let source = buffer.floatChannelData,
              let first = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let target = first.floatChannelData
        else { return nil }
        first.frameLength = buffer.frameLength
        let stride = buffer.stride
        for frame in 0..<Int(buffer.frameLength) {
            target[0][frame] = source[0][frame * stride]
        }
        let ratio = VoiceCapture.fileFormat.sampleRate / mono.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: VoiceCapture.fileFormat, frameCapacity: capacity)
        else { return nil }
        var handed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if handed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            handed = true
            inputStatus.pointee = .haveData
            return first
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}
