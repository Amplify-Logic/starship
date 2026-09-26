import AVFoundation
import CoreAudio
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
///
/// Switching voice processing on takes one to two seconds, and nothing is
/// recorded until it is done, so an engine built on each key press lost the
/// captain's first words. One engine is therefore built ahead of the first
/// press (warm) and kept; a capture then only starts it, in well under a tenth
/// of a second. A built engine that is not started does not run the
/// microphone. An engine whose audio setup changes (headphones connected, a
/// new default input or output, a new input format) is rebuilt as soon as no
/// capture is running, so the next press is quick again; one that stops
/// working, or whose setup changes during a capture, is rebuilt on the next
/// capture. A change notification that leaves the setup as it was, such as
/// the one a new engine receives when the engine it replaced is torn down, is
/// ignored.
///
/// Audio still on its way in when the key comes up (up to one tap buffer, a
/// tenth of a second) would be lost by stopping at once, and a release often
/// lands on the last syllable, so a finished capture keeps recording for
/// `releaseTail` before the file is closed.
final class VoiceCapture {
    /// The format of the file handed to transcription.
    static let fileFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    /// How long a finished capture keeps recording before the file is closed.
    static let releaseTail: TimeInterval = 0.4

    private let makeEngine: () throws -> CaptureEngine
    private var engine: CaptureEngine?
    private var builtFor: AudioSetup?
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: CaptureConverter?

    init(makeEngine: @escaping () throws -> CaptureEngine = { try VoiceEngine() }) {
        self.makeEngine = makeEngine
    }

    /// Builds the engine now, so the next capture starts at once; a no-op
    /// while a working engine is already built.
    func warm() throws {
        if let engine, engine.setup == builtFor {
            return
        }
        engine = nil
        let engine = try makeEngine()
        engine.onChange = { [weak self] in
            DispatchQueue.main.async { self?.rebuildIfIdle() }
        }
        self.engine = engine
        builtFor = engine.setup
    }

    private func rebuildIfIdle() {
        guard lock.withLock({ file == nil }) else { return }
        try? warm()
    }

    /// Starts recording into a new file at `url`.
    func start(writingTo url: URL) throws {
        do {
            try begin(writingTo: url)
        } catch {
            // A kept engine can stop working (a device went away, the audio
            // system restarted): build a fresh one and try once more.
            engine = nil
            try begin(writingTo: url)
        }
    }

    private func begin(writingTo url: URL) throws {
        try warm()
        guard let engine else { throw CaptureConverter.Unsupported() }
        let converter = try CaptureConverter(from: engine.inputFormat)
        let file = try AVAudioFile(
            forWriting: url, settings: Self.fileFormat.settings,
            commonFormat: .pcmFormatInt16, interleaved: true)
        lock.withLock {
            self.converter = converter
            self.file = file
        }
        engine.installTap { [weak self] buffer in
            self?.write(buffer)
        }
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    /// Keeps recording for `tail`, then stops and closes the file and calls
    /// `done` on the main queue.
    func finish(after tail: TimeInterval = releaseTail, done: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + tail) { [self] in
            stop()
            MainActor.assumeIsolated { done() }
        }
    }

    /// Stops capturing and closes the file at once; safe to call more than
    /// once. The engine is kept for the next capture.
    func stop() {
        engine?.removeTap()
        engine?.stop()
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

/// The audio engine a capture records from: the microphone with voice
/// processing, or a stand-in in tests.
protocol CaptureEngine: AnyObject {
    /// The format of the buffers handed to the tap.
    var inputFormat: AVAudioFormat { get }
    /// The audio devices and input format as they are now.
    var setup: AudioSetup { get }
    /// Called, on any thread, when the audio configuration may have changed.
    var onChange: (() -> Void)? { get set }
    func installTap(_ block: @escaping (AVAudioPCMBuffer) -> Void)
    func removeTap()
    func start() throws
    func stop()
}

/// The microphone through macOS voice processing. Building one does the slow
/// part; starting and stopping it are quick.
final class VoiceEngine: CaptureEngine {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    var onChange: (() -> Void)?

    init() throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: true, duckingLevel: .min)
        engine.prepare()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.onChange?()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    var setup: AudioSetup {
        AudioSetup(
            format: inputFormat,
            input: Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
            output: Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    func installTap(_ block: @escaping (AVAudioPCMBuffer) -> Void) {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buffer, _ in
            block(buffer)
        }
    }

    func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    func start() throws {
        try engine.start()
    }

    func stop() {
        engine.stop()
    }
}

/// What an engine is built for: the system's default input and output devices
/// and the format the input delivers.
struct AudioSetup: Equatable {
    var format: AVAudioFormat
    var input: AudioDeviceID
    var output: AudioDeviceID
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
