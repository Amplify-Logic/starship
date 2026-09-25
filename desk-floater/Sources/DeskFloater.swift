import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

@main
struct DeskFloaterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloaterPanel?
    private var hotkeys: HotkeyMonitor?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let root = ProcessInfo.processInfo.environment["FM_DESK_FLOATER_ROOT"]
            ?? FileManager.default.currentDirectoryPath
        let home = ProcessInfo.processInfo.environment["FM_HOME"]
            ?? root
        let model = FloaterModel(repoRoot: root, fmHome: home)
        let panel = FloaterPanel(model: model)
        panel.orderFrontRegardless()
        self.panel = panel

        let hotkeys = HotkeyMonitor()
        hotkeys.onTalkDown = { [weak model] in model?.hotkeyTalkBegan() }
        hotkeys.onTalkUp = { [weak model] in model?.hotkeyTalkEnded() }
        hotkeys.onTalkChord = { [weak model] in model?.hotkeyTalkChorded() }
        hotkeys.onDictateTap = { [weak model] in model?.toggleDictation() }
        hotkeys.onTrustChanged = { [weak model] trusted in model?.keysTrusted = trusted }
        model.onFixKeys = { [weak hotkeys] in hotkeys?.requestAccess() }
        hotkeys.start()
        self.hotkeys = hotkeys
        model.refreshMute()
    }
}

final class FloaterPanel: NSPanel {
    @MainActor
    init(model: FloaterModel) {
        let mover = WindowMover()
        let view = FloaterView(model: model, mover: mover)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        super.init(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        mover.window = self
        self.contentView = hosting
        self.isFloatingPanel = true
        // Clicking a control must never take keyboard focus from the app the
        // captain is typing in: dictation pastes into whatever has the cursor.
        self.becomesKeyOnlyIfNeeded = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            self.setFrameOrigin(NSPoint(x: f.maxX - hosting.frame.width - 24, y: f.midY))
        }
    }

    override var canBecomeKey: Bool { true }
}

/// Moves the floater with the pointer while its backing plate is dragged.
final class WindowMover {
    weak var window: NSWindow?
    private var startOrigin: NSPoint?
    private var startMouse: NSPoint?

    func drag() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        if startOrigin == nil {
            startOrigin = window.frame.origin
            startMouse = mouse
        }
        guard let origin = startOrigin, let start = startMouse else { return }
        window.setFrameOrigin(NSPoint(x: origin.x + mouse.x - start.x, y: origin.y + mouse.y - start.y))
    }

    func end() {
        startOrigin = nil
        startMouse = nil
    }
}

/// Global keys: Right Option held is push-to-talk to Firstmate, and a lone tap of
/// Right Command starts or finishes dictation. Watching keys in other apps, and
/// typing the dictated text into them, both need the Accessibility permission.
/// macOS ties that grant to the exact build, so a rebuilt floater is untrusted
/// again: it asks once per build, and the keys-off badge asks again on demand.
@MainActor
final class HotkeyMonitor {
    var onTalkDown: (() -> Void)?
    var onTalkUp: (() -> Void)?
    var onTalkChord: (() -> Void)?
    var onDictateTap: (() -> Void)?
    var onTrustChanged: ((Bool) -> Void)?

    private static let rightOptionKey: UInt16 = 61
    private static let rightCommandKey: UInt16 = 54
    // Device-dependent modifier bits that tell the right-hand key from the left.
    private static let rightOptionBit: UInt = 0x40
    private static let rightCommandBit: UInt = 0x10
    private static let askedKey = "askedForAccessibilityBuild"
    private let tapLimit: TimeInterval = 0.5

    private var monitors: [Any] = []
    private var trustTimer: Timer?
    private var trusted = false
    private var talkDown = false
    private var commandDownAt: Date?
    private var commandChorded = false

    func start() {
        let defaults = UserDefaults.standard
        let build = Self.buildStamp()
        if !AXIsProcessTrusted() && defaults.string(forKey: Self.askedKey) != build {
            defaults.set(build, forKey: Self.askedKey)
            Self.prompt()
        }
        checkTrust()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTrust() }
        }
    }

    /// Asks for the permission again and opens its Settings pane. A rebuilt
    /// floater can still be listed there as switched on while macOS ignores the
    /// old grant, so the pane is where the captain switches it off and on.
    func requestAccess() {
        Self.prompt()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        checkTrust()
    }

    private static func prompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Identifies this exact build, so a rebuild is asked about once more.
    private static func buildStamp() -> String {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return "\(path)|\(modified)|\(size)"
    }

    private func checkTrust() {
        let now = AXIsProcessTrusted()
        guard now != trusted || (now && monitors.isEmpty) else { return }
        trusted = now
        onTrustChanged?(now)
        removeMonitors()
        if now {
            installMonitors()
        }
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }

    private func handle(_ event: NSEvent) {
        if event.type != .flagsChanged {
            // Any key or click while a hotkey is held makes it a shortcut, not a
            // hotkey: Option-letter types a character, Command-click opens a link.
            if talkDown {
                talkDown = false
                onTalkChord?()
            }
            if commandDownAt != nil {
                commandChorded = true
            }
            return
        }
        let raw = event.modifierFlags.rawValue
        if event.keyCode != Self.rightCommandKey && commandDownAt != nil {
            commandChorded = true
        }
        switch event.keyCode {
        case Self.rightOptionKey:
            let down = raw & Self.rightOptionBit != 0
            if down && !talkDown {
                talkDown = true
                onTalkDown?()
            } else if !down && talkDown {
                talkDown = false
                onTalkUp?()
            }
        case Self.rightCommandKey:
            let down = raw & Self.rightCommandBit != 0
            if down {
                commandDownAt = Date()
                commandChorded = hasOtherModifiers(event.modifierFlags)
            } else if let started = commandDownAt {
                commandDownAt = nil
                if !commandChorded && Date().timeIntervalSince(started) < tapLimit {
                    onDictateTap?()
                }
            }
        default:
            break
        }
    }

    private func hasOtherModifiers(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.intersection([.shift, .control, .option, .function]).isEmpty
    }
}

/// Types text into whatever has the cursor by pasting it: the text goes on the
/// clipboard, Command-V goes to the focused app, and the clipboard the captain
/// had before is put back.
enum Paster {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func paste(_ text: String) -> Bool {
        let board = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (board.pasteboardItems ?? [])
            .filter { item in !item.types.contains(concealed) && !item.types.contains(transient) }
            .map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transient)
        board.writeObjects([item])
        guard AXIsProcessTrusted() else {
            // Without the permission no keystroke can be sent, so the text is
            // left on the clipboard for the captain to paste by hand.
            return false
        }
        let ours = board.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Something else copied in the meantime: leave its contents alone.
            guard board.changeCount == ours else { return }
            board.clearContents()
            let items: [NSPasteboardItem] = saved.map { pairs in
                let item = NSPasteboardItem()
                for (type, data) in pairs {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !items.isEmpty {
                board.writeObjects(items)
            }
        }
        return true
    }
}

@MainActor
final class FloaterModel: ObservableObject {
    enum Mode {
        case idle
        case starting
        case recording
        case busy
    }

    /// Where a capture's transcript goes: Firstmate's mailbox, or typed into
    /// the focused text box. Dictated text never reaches the mailbox.
    enum Purpose {
        case firstmate
        case dictate
    }

    @Published var mode: Mode = .idle
    @Published var purpose: Purpose = .firstmate
    @Published var status: String = "Hold to talk"
    @Published var muted = false
    @Published var keysTrusted = false {
        didSet {
            if mode == .idle {
                status = idleStatus
            }
        }
    }

    let repoRoot: String
    let fmHome: String
    private var recorder: AVAudioRecorder?
    private var recordURL: URL?
    private var pressStartedAt: Date?
    private var latched = false
    private var fromHotkey = false
    private let tapWindow: TimeInterval = 0.3
    private var muteTimer: Timer?

    init(repoRoot: String, fmHome: String) {
        self.repoRoot = repoRoot
        self.fmHome = fmHome
        muteTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMute() }
        }
    }

    var idleStatus: String { keysTrusted ? "Hold to talk" : "Keys off - click !" }

    /// Asks macOS for the Accessibility permission again (the keys-off badge).
    var onFixKeys: (() -> Void)?

    func fixKeys() {
        onFixKeys?()
    }

    // MARK: main button (talk to Firstmate)

    func toggle() {
        switch mode {
        case .idle:
            pressBegan()
            latched = true
        case .recording where purpose == .firstmate:
            stopAndDeliver()
        case .starting, .recording, .busy:
            break
        }
    }

    func pressBegan() {
        switch mode {
        case .idle:
            begin(.firstmate)
            pressStartedAt = Date()
        case .recording where latched && purpose == .firstmate && !fromHotkey:
            stopAndDeliver()
        case .starting, .recording, .busy:
            break
        }
    }

    func pressEnded() {
        guard purpose == .firstmate, !fromHotkey else { return }
        let quick = pressStartedAt.map { Date().timeIntervalSince($0) < tapWindow } ?? false
        pressStartedAt = nil
        switch mode {
        case .starting:
            if quick {
                latched = true
            } else {
                cancelCapture()
            }
        case .recording:
            if latched {
                break
            }
            if quick {
                latched = true
                status = "Listening… (click to stop)"
            } else {
                stopAndDeliver()
            }
        case .idle, .busy:
            break
        }
    }

    // MARK: Right Option (hold to talk to Firstmate)

    func hotkeyTalkBegan() {
        guard mode == .idle else { return }
        begin(.firstmate)
        fromHotkey = true
        pressStartedAt = Date()
    }

    func hotkeyTalkEnded() {
        guard fromHotkey else { return }
        let quick = pressStartedAt.map { Date().timeIntervalSince($0) < tapWindow } ?? true
        switch mode {
        case .starting:
            cancelCapture()
        case .recording:
            // A brush of the key is not a message: nothing is sent for it.
            if quick {
                cancelCapture()
            } else {
                stopAndDeliver()
            }
        case .idle, .busy:
            break
        }
    }

    func hotkeyTalkChorded() {
        guard fromHotkey, mode == .starting || mode == .recording else { return }
        cancelCapture()
    }

    // MARK: dictation (Type button, or a tap of Right Command)

    func toggleDictation() {
        switch mode {
        case .idle:
            begin(.dictate)
            latched = true
        case .starting where purpose == .dictate:
            cancelCapture()
        case .recording where purpose == .dictate:
            stopAndDeliver()
        case .starting, .recording, .busy:
            break
        }
    }

    // MARK: voice-out controls

    func stopTalking() {
        runSpeak(["--stop"]) { ok in ok ? "Stopped" : "Stop failed" }
    }

    func repeatLast() {
        guard !muted else {
            if mode == .idle {
                finish(status: "Voice muted")
            }
            return
        }
        runSpeak(["--repeat"]) { ok in ok ? "Repeating" : "Nothing to repeat" }
    }

    func toggleMute() {
        let wasMuted = muted
        muted.toggle()
        runSpeak([wasMuted ? "--unmute" : "--mute"]) { ok in
            ok ? (wasMuted ? "Voice on" : "Voice muted") : "Mute failed"
        }
    }

    func refreshMute() {
        Task.detached(priority: .utility) { [repoRoot, fmHome] in
            let out = Self.speak(repoRoot: repoRoot, fmHome: fmHome, args: ["--muted"])
            let muted = out?.trimmingCharacters(in: .whitespacesAndNewlines) == "muted"
            await MainActor.run {
                self.muted = muted
            }
        }
    }

    private func runSpeak(_ args: [String], status message: @escaping @Sendable (Bool) -> String) {
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            let ok = Self.speak(repoRoot: repoRoot, fmHome: fmHome, args: args) != nil
            await MainActor.run {
                if self.mode == .idle {
                    self.finish(status: message(ok))
                }
                self.refreshMute()
            }
        }
    }

    // MARK: capture

    private func begin(_ purpose: Purpose) {
        self.purpose = purpose
        mode = .starting
        status = "Starting…"
        latched = false
        fromHotkey = false
        pressStartedAt = nil
        startRecording()
    }

    private var listeningStatus: String {
        if purpose == .dictate {
            return "Dictating… tap to end"
        }
        return latched ? "Listening… (click to stop)" : "Listening…"
    }

    private func startRecording() {
        Task {
            let ok = await requestMic()
            guard mode == .starting else { return }
            guard ok else {
                mode = .idle
                status = "Mic denied"
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("fm-desk-\(UUID().uuidString).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            do {
                let rec = try AVAudioRecorder(url: url, settings: settings)
                rec.prepareToRecord()
                guard rec.record() else {
                    mode = .idle
                    status = "Record failed"
                    return
                }
                guard mode == .starting else {
                    rec.stop()
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                recorder = rec
                recordURL = url
                mode = .recording
                status = listeningStatus
            } catch {
                mode = .idle
                status = "Record error"
            }
        }
    }

    private func cancelCapture() {
        latched = false
        fromHotkey = false
        pressStartedAt = nil
        recorder?.stop()
        recorder = nil
        if let url = recordURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordURL = nil
        mode = .idle
        purpose = .firstmate
        status = idleStatus
    }

    private func stopAndDeliver() {
        let purpose = self.purpose
        latched = false
        fromHotkey = false
        pressStartedAt = nil
        recorder?.stop()
        recorder = nil
        guard let url = recordURL else {
            mode = .idle
            self.purpose = .firstmate
            status = idleStatus
            return
        }
        recordURL = nil
        mode = .busy
        status = "Transcribing…"
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            let transcript = Self.transcribe(repoRoot: repoRoot, fmHome: fmHome, audio: url)
            try? FileManager.default.removeItem(at: url)
            let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                await MainActor.run {
                    self.finish(status: "No speech")
                }
                return
            }
            switch purpose {
            case .dictate:
                await MainActor.run {
                    let typed = Paster.paste(text)
                    self.finish(status: typed ? "Typed" : "Copied - press ⌘V")
                }
            case .firstmate:
                await MainActor.run {
                    self.status = "Delivering…"
                }
                let outcome = Self.deliver(repoRoot: repoRoot, fmHome: fmHome, text: text)
                await MainActor.run {
                    self.finish(status: outcome)
                }
            }
        }
    }

    private func finish(status: String) {
        mode = .idle
        purpose = .firstmate
        self.status = status
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if self.mode == .idle {
                self.status = self.idleStatus
            }
        }
    }

    private func requestMic() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    nonisolated private static func transcribe(repoRoot: String, fmHome: String, audio: URL) -> String? {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-deepgram-stt.sh")
        return run(bin: bin, args: [audio.path], env: ["FM_HOME": fmHome])
    }

    // Types the transcript into firstmate's own chat; bin/fm-desk-voice.sh
    // falls back to its mailbox when that pane cannot be reached.
    nonisolated private static func deliver(repoRoot: String, fmHome: String, text: String) -> String {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-desk-voice.sh")
        guard let out = run(bin: bin, args: ["send", "--source", "desk-floater", text], env: ["FM_HOME": fmHome]) else {
            return "Deliver failed"
        }
        if out.hasPrefix("sent:") { return "Sent" }
        if out.hasPrefix("sent-unconfirmed:") { return "Sent, unconfirmed" }
        return "Saved to mailbox"
    }

    nonisolated private static func speak(repoRoot: String, fmHome: String, args: [String]) -> String? {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-speak.sh")
        return run(bin: bin, args: args, env: ["FM_HOME": fmHome])
    }

    nonisolated private static func run(bin: String, args: [String], env: [String: String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        proc.environment = environment
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.standardError
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct FloaterView: View {
    @ObservedObject var model: FloaterModel
    let mover: WindowMover

    private let mainSize: CGFloat = 36
    private let controlSize: CGFloat = 20

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                mainButton
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        control("stop.fill", help: "Stop talking", action: model.stopTalking)
                        control("arrow.counterclockwise", help: "Repeat the last reply", action: model.repeatLast)
                    }
                    HStack(spacing: 4) {
                        control(
                            model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            help: model.muted ? "Voice muted - click to unmute" : "Mute voice",
                            tint: model.muted ? Color(red: 0.85, green: 0.45, blue: 0.10) : nil,
                            action: model.toggleMute
                        )
                        control(
                            dictating ? "keyboard.fill" : "character.cursor.ibeam",
                            help: dictating ? "Finish dictation" : "Dictate into the text box with the cursor (or tap Right Command)",
                            tint: dictating ? dictateColor : nil,
                            action: model.toggleDictation
                        )
                    }
                }
            }
            Text(model.status)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(keysOffIdle ? Color(red: 1.0, green: 0.72, blue: 0.35) : Color.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 104)
                .allowsHitTesting(false)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.55))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { _ in mover.drag() }
                        .onEnded { _ in mover.end() }
                )
        )
        .fixedSize()
    }

    private var dictating: Bool {
        model.purpose == .dictate && model.mode != .idle
    }

    private var keysOffIdle: Bool {
        !model.keysTrusted && model.mode == .idle
    }

    private var dictateColor: Color { Color(red: 0.55, green: 0.30, blue: 0.85) }

    private var mainButton: some View {
        ZStack {
            Circle()
                .fill(color)
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: mainSize, height: mainSize)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in model.pressBegan() }
                .onEnded { _ in model.pressEnded() }
        )
        .onTapGesture(count: 2) {
            model.toggle()
        }
        .help("Hold to talk to Firstmate, or click to start and click again to send (or hold Right Option)")
        .accessibilityLabel("Desk push to talk")
        .overlay(alignment: .topTrailing) {
            if !model.keysTrusted {
                keysOffBadge
                    .offset(x: 4, y: -4)
            }
        }
    }

    /// Shown while macOS has not granted this build Accessibility, so the
    /// hotkeys and dictation paste are off; clicking it asks again.
    private var keysOffBadge: some View {
        Button(action: model.fixKeys) {
            Image(systemName: "exclamationmark")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color(red: 0.90, green: 0.50, blue: 0.10)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Hotkeys are off: macOS has not allowed this build Accessibility. Click to allow it.")
        .accessibilityLabel("Hotkeys off - allow Accessibility")
    }

    private func control(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: controlSize, height: controlSize)
                .background(Circle().fill(tint ?? Color.white.opacity(0.22)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var color: Color {
        if model.purpose == .dictate && model.mode != .idle {
            return dictateColor
        }
        switch model.mode {
        case .idle: return Color(red: 0.12, green: 0.45, blue: 0.85)
        case .starting: return Color(red: 0.85, green: 0.55, blue: 0.20)
        case .recording: return Color(red: 0.85, green: 0.20, blue: 0.20)
        case .busy: return Color(red: 0.35, green: 0.35, blue: 0.40)
        }
    }

    private var icon: String {
        if model.purpose == .dictate && model.mode == .recording {
            return "text.cursor"
        }
        switch model.mode {
        case .idle: return "mic.fill"
        case .starting: return "mic"
        case .recording: return "waveform"
        case .busy: return "hourglass"
        }
    }
}
