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
    private var screen: ScreenAccess?

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
        hotkeys.onShotTap = { [weak model] in model?.takeShot() }
        hotkeys.onTrustChanged = { [weak model] trusted in model?.keysTrusted = trusted }
        model.onFixKeys = { [weak hotkeys] in hotkeys?.requestAccess() }
        hotkeys.start()
        self.hotkeys = hotkeys

        let screen = ScreenAccess()
        screen.onChanged = { [weak model] granted in model?.screenTrusted = granted }
        model.onFixScreen = { [weak screen] in screen?.requestAccess() }
        screen.start()
        self.screen = screen
        model.refreshMute()
    }
}

final class FloaterPanel: NSPanel {
    @MainActor
    init(model: FloaterModel) {
        let mover = WindowMover()
        let view = FloaterView(model: model, mover: mover)
        let hosting = NSHostingView(rootView: view)
        // WindowMover sizes the window: left to itself the hosting view would
        // grow it from the top-left corner and push the controls off-screen.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        super.init(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
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
        // Only once the panel is placed, so the first fit anchors to where the
        // captain sees it rather than to the origin it was created at.
        mover.window = self
    }

    override var canBecomeKey: Bool { true }
}

/// Moves the floater with the pointer while its backing plate is dragged, and
/// resizes it when the recent-replies list opens or closes. The top-right
/// corner stays put, so the controls do not jump and the list drops down and
/// to the left of them.
final class WindowMover {
    weak var window: NSWindow?
    private var startOrigin: NSPoint?
    private var startMouse: NSPoint?
    private var anchor: NSPoint?
    private var fitted: NSRect?

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

    func fit(_ size: CGSize) {
        guard let window, size.width > 0, size.height > 0 else { return }
        let frame = window.frame
        let corner = (frame == fitted ? anchor : nil) ?? NSPoint(x: frame.maxX, y: frame.maxY)
        anchor = corner
        var rect = NSRect(x: corner.x - size.width, y: corner.y - size.height, width: size.width, height: size.height)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            rect.origin.x = max(min(rect.origin.x, visible.maxX - rect.width), visible.minX)
            rect.origin.y = max(min(rect.origin.y, visible.maxY - rect.height), visible.minY)
        }
        if rect != frame {
            window.setFrame(rect, display: true)
            window.invalidateShadow()
        }
        fitted = window.frame
    }

    func end() {
        startOrigin = nil
        startMouse = nil
    }
}

/// A modifier key that acts on a lone tap: pressed and released within the tap
/// limit, with no other key, click or modifier used while it was down.
struct TapKey {
    let keyCode: UInt16
    // Device-dependent modifier bit that tells the right-hand key from the left.
    let bit: UInt
    let flag: NSEvent.ModifierFlags
    private var downAt: Date?
    private var chorded = false

    init(keyCode: UInt16, bit: UInt, flag: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.bit = bit
        self.flag = flag
    }

    static let rightCommand = TapKey(keyCode: 54, bit: 0x10, flag: .command)
    static let rightShift = TapKey(keyCode: 60, bit: 0x04, flag: .shift)

    /// A key press or click while this key is down makes it part of a shortcut.
    mutating func chord() {
        if downAt != nil {
            chorded = true
        }
    }

    /// Feeds one modifier change; true when it completes a lone tap. Modifiers
    /// in `allowed` may already be held without making the press a shortcut.
    mutating func update(_ event: NSEvent, allowed: NSEvent.ModifierFlags, limit: TimeInterval) -> Bool {
        guard event.keyCode == keyCode else {
            chord()
            return false
        }
        if event.modifierFlags.rawValue & bit != 0 {
            let others = NSEvent.ModifierFlags([.shift, .control, .option, .command, .function])
                .subtracting(flag)
                .subtracting(allowed)
            downAt = Date()
            chorded = !event.modifierFlags.intersection(others).isEmpty
            return false
        }
        guard let started = downAt else { return false }
        downAt = nil
        return !chorded && Date().timeIntervalSince(started) < limit
    }
}

/// Global keys: Right Option held is push-to-talk to Firstmate, a lone tap of
/// Right Command starts or finishes dictation, and a lone tap of Right Shift
/// takes a screenshot. Watching keys in other apps, and typing the dictated text
/// into them, both need the Accessibility permission. macOS ties that grant to
/// the exact build, so a rebuilt floater is untrusted again: it asks once per
/// build, and the keys-off badge asks again on demand.
@MainActor
final class HotkeyMonitor {
    var onTalkDown: (() -> Void)?
    var onTalkUp: (() -> Void)?
    var onTalkChord: (() -> Void)?
    var onDictateTap: (() -> Void)?
    var onShotTap: (() -> Void)?
    var onTrustChanged: ((Bool) -> Void)?

    private static let rightOptionKey: UInt16 = 61
    // Device-dependent modifier bit that tells the right-hand key from the left.
    private static let rightOptionBit: UInt = 0x40
    private static let askedKey = "askedForAccessibilityBuild"
    private let tapLimit: TimeInterval = 0.5

    private var monitors: [Any] = []
    private var trustTimer: Timer?
    private var trusted = false
    private var talkDown = false
    private var dictateKey = TapKey.rightCommand
    private var shotKey = TapKey.rightShift

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
    static func buildStamp() -> String {
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
            dictateKey.chord()
            shotKey.chord()
            return
        }
        if event.keyCode == Self.rightOptionKey {
            let down = event.modifierFlags.rawValue & Self.rightOptionBit != 0
            if down && !talkDown {
                talkDown = true
                onTalkDown?()
            } else if !down && talkDown {
                talkDown = false
                onTalkUp?()
            }
        }
        if dictateKey.update(event, allowed: [], limit: tapLimit) {
            onDictateTap?()
        }
        // Screenshots taken while Right Option is held join that voice message.
        if shotKey.update(event, allowed: talkDown ? .option : [], limit: tapLimit) {
            onShotTap?()
        }
    }
}

/// The Screen Recording permission screenshots need. Like Accessibility, macOS
/// ties it to the exact build: it is asked for once per build, checked every few
/// seconds, and asked for again from the camera button's badge.
@MainActor
final class ScreenAccess {
    var onChanged: ((Bool) -> Void)?

    private static let askedKey = "askedForScreenRecordingBuild"
    private var timer: Timer?
    private var granted: Bool?

    func start() {
        let defaults = UserDefaults.standard
        let build = HotkeyMonitor.buildStamp()
        if !CGPreflightScreenCaptureAccess() && defaults.string(forKey: Self.askedKey) != build {
            defaults.set(build, forKey: Self.askedKey)
            _ = CGRequestScreenCaptureAccess()
        }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func requestAccess() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        check()
    }

    private func check() {
        let now = CGPreflightScreenCaptureAccess()
        guard now != granted else { return }
        granted = now
        onChanged?(now)
    }

    /// screencapture's number (from 1, the main display first) for the display
    /// under the mouse pointer, or nil to let it take the main display.
    static func displayUnderPointer() -> Int? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        var hit: CGDirectDisplayID = 0
        var hits: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &hit, &hits) == .success, hits > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).firstIndex(of: hit).map { $0 + 1 }
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

/// Screenshots waiting to go to Firstmate, and the talk-to-Firstmate words held
/// to go with them. They go as one message once `window` has passed since the
/// last shot or the end of the last talk, so each new one restarts the wait.
struct ShotStack {
    static let window: TimeInterval = 3

    private(set) var shots: [String] = []
    private(set) var inFlight = 0
    private(set) var transcript: String?
    private var lastActivity: Date?

    /// Shots taken and not yet sent, counting any still being captured.
    var count: Int { shots.count + inFlight }
    var isEmpty: Bool { transcript == nil && count == 0 }
    /// When the stack may go, unless a capture or a talk is still under way.
    var dueAt: Date { (lastActivity ?? .distantPast).addingTimeInterval(Self.window) }

    mutating func shotStarted(at now: Date) {
        inFlight += 1
        touch(now)
    }

    /// A capture finished: its image path, or nil when it failed.
    mutating func shotFinished(_ path: String?, at now: Date) {
        inFlight -= 1
        if let path {
            shots.append(path)
            touch(now)
        }
    }

    mutating func talkEnded(at now: Date) {
        touch(now)
    }

    /// Holds a transcript to go with the stack, after any words already held.
    /// False when nothing is stacked, so the words should go at once instead.
    mutating func hold(_ text: String) -> Bool {
        if let held = transcript {
            transcript = held + " " + text
            return true
        }
        guard count > 0 else { return false }
        transcript = text
        return true
    }

    func ready(at now: Date) -> Bool {
        !isEmpty && inFlight == 0 && now >= dueAt
    }

    /// Empties the stack, returning the message it held.
    mutating func take() -> (text: String?, images: [String]) {
        defer {
            transcript = nil
            shots = []
        }
        return (transcript, shots)
    }

    private mutating func touch(_ now: Date) {
        lastActivity = max(lastActivity ?? now, now)
    }
}

/// One reply from the speak-out history, as `bin/fm-speak.sh --history` lists it.
struct RecentReply: Identifiable, Equatable {
    let id: Int
    let time: Date
    let text: String
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
    @Published var recent: [RecentReply] = []
    @Published var showingRecent = false
    @Published var keysTrusted = false {
        didSet {
            if mode == .idle {
                status = idleStatus
            }
        }
    }
    @Published var screenTrusted = false
    /// Screenshots taken and not yet sent, counting any still being captured.
    @Published var shotCount = 0

    let repoRoot: String
    let fmHome: String
    private var recorder: AVAudioRecorder?
    private var recordURL: URL?
    private var pressStartedAt: Date?
    private var latched = false
    private var fromHotkey = false
    private let tapWindow: TimeInterval = 0.3
    private var muteTimer: Timer?

    // Screenshots stack until the captain stops taking them, then go to
    // Firstmate as one message. A talk-to-Firstmate message recorded or
    // transcribed meanwhile takes them along instead, so the two arrive as one.
    private var stack = ShotStack()
    private var shotTimer: Timer?

    init(repoRoot: String, fmHome: String) {
        self.repoRoot = repoRoot
        self.fmHome = fmHome
        muteTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshMute()
                if self?.showingRecent == true {
                    self?.refreshRecent()
                }
            }
        }
    }

    var idleStatus: String {
        if stack.transcript != nil {
            return "Adding shots…"
        }
        if shotCount > 0 {
            return shotCount == 1 ? "1 shot stacked" : "\(shotCount) shots stacked"
        }
        return keysTrusted ? "Hold to talk" : "Keys off - click !"
    }

    /// Asks macOS for the Accessibility permission again (the keys-off badge).
    var onFixKeys: (() -> Void)?

    func fixKeys() {
        onFixKeys?()
    }

    /// Asks macOS for the Screen Recording permission again (the camera badge).
    var onFixScreen: (() -> Void)?

    // MARK: screenshots (camera button, or a tap of the screenshot key)

    func shotButton() {
        if screenTrusted {
            takeShot()
        } else {
            onFixScreen?()
        }
    }

    /// Captures the display under the pointer and adds it to the stack.
    func takeShot() {
        guard screenTrusted else {
            flash("Screen off - click !")
            return
        }
        let display = ScreenAccess.displayUnderPointer()
        stack.shotStarted(at: Date())
        shotsChanged()
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            let path = Self.shoot(repoRoot: repoRoot, fmHome: fmHome, display: display)
            await MainActor.run {
                self.stack.shotFinished(path, at: Date())
                self.shotsChanged()
                if path == nil {
                    self.flash("Shot failed")
                }
                self.scheduleFlush()
            }
        }
    }

    /// A talk-to-Firstmate message is being recorded or transcribed, so stacked
    /// shots wait to go with it.
    private var voiceInProgress: Bool {
        purpose == .firstmate && mode != .idle
    }

    private func shotsChanged() {
        shotCount = stack.count
        if mode == .idle {
            status = idleStatus
        }
    }

    private func scheduleFlush() {
        shotTimer?.invalidate()
        let delay = max(0.1, stack.dueAt.timeIntervalSinceNow)
        shotTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushShots() }
        }
    }

    private func flushShots() {
        shotTimer = nil
        guard !stack.isEmpty else { return }
        if voiceInProgress || !stack.ready(at: Date()) {
            // A capture is still being written, the stack is waiting for a voice
            // message, or the window has not passed: look again shortly.
            shotTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushShots() }
            }
            return
        }
        let (text, images) = stack.take()
        shotsChanged()
        if mode == .idle {
            if text != nil {
                status = "Delivering…"
            } else {
                status = images.count == 1 ? "Sending 1 shot…" : "Sending \(images.count) shots…"
            }
        }
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            let outcome = Self.deliver(repoRoot: repoRoot, fmHome: fmHome, text: text, images: images)
            await MainActor.run {
                self.flash(outcome)
            }
        }
    }

    /// A transcribed talk-to-Firstmate message: sent at once when nothing is
    /// stacked, otherwise held until the stack window closes and sent with the
    /// shots. The floater is free meanwhile, so another talk joins the same message.
    private func voiceTranscribed(_ text: String) {
        guard stack.hold(text) else {
            status = "Delivering…"
            Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
                let outcome = Self.deliver(repoRoot: repoRoot, fmHome: fmHome, text: text, images: [])
                await MainActor.run {
                    self.finish(status: outcome)
                }
            }
            return
        }
        mode = .idle
        purpose = .firstmate
        status = idleStatus
        scheduleFlush()
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

    func toggleRecent() {
        showingRecent.toggle()
        if showingRecent {
            refreshRecent()
        }
    }

    /// Speaks one reply from the recent list again; stays silent while muted,
    /// exactly like Repeat.
    func replay(_ reply: RecentReply) {
        guard !muted else {
            if mode == .idle {
                finish(status: "Voice muted")
            }
            return
        }
        runSpeak(["--replay", String(reply.id)]) { ok in ok ? "Replaying" : "No longer kept" }
    }

    func refreshRecent() {
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            let out = Self.speak(repoRoot: repoRoot, fmHome: fmHome, args: ["--history"]) ?? ""
            let replies = Self.parseHistory(out)
            await MainActor.run {
                if self.recent != replies {
                    self.recent = replies
                }
            }
        }
    }

    /// Reads `<number> TAB <epoch> TAB <text>` lines, newest first.
    nonisolated private static func parseHistory(_ out: String) -> [RecentReply] {
        out.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard cols.count == 3, let id = Int(cols[0]), let epoch = TimeInterval(cols[1]) else {
                return nil
            }
            return RecentReply(id: id, time: Date(timeIntervalSince1970: epoch), text: String(cols[2]))
        }
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
                if self.showingRecent {
                    self.refreshRecent()
                }
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
        if purpose == .firstmate {
            stack.talkEnded(at: Date())
        }
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
                    self.voiceTranscribed(text)
                }
            }
        }
    }

    private func finish(status: String) {
        mode = .idle
        purpose = .firstmate
        flash(status)
    }

    /// Shows a short outcome on the status line while nothing is being captured.
    private func flash(_ message: String) {
        guard mode == .idle else { return }
        status = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if self.mode == .idle && self.status == message {
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

    /// Sends one message to Firstmate: the transcript, the screenshots, or both,
    /// and returns the status to show. It is typed into firstmate's own chat;
    /// bin/fm-desk-voice.sh falls back to its mailbox when that pane cannot be
    /// reached.
    nonisolated private static func deliver(repoRoot: String, fmHome: String, text: String?, images: [String]) -> String {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-desk-voice.sh")
        var args = ["send", "--source", "desk-floater"]
        for image in images {
            args += ["--image", image]
        }
        args.append("--")
        if let text {
            args.append(text)
        }
        guard let out = run(bin: bin, args: args, env: ["FM_HOME": fmHome]) else {
            return "Deliver failed"
        }
        if out.hasPrefix("sent:") { return "Sent" }
        if out.hasPrefix("sent-unconfirmed:") { return "Sent, unconfirmed" }
        return "Saved to mailbox"
    }

    /// Captures one display to this home's screenshot folder; nil on failure.
    nonisolated private static func shoot(repoRoot: String, fmHome: String, display: Int?) -> String? {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-desk-voice.sh")
        var args = ["shot"]
        if let display {
            args += ["--display", String(display)]
        }
        let path = run(bin: bin, args: args, env: ["FM_HOME": fmHome])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
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
        VStack(alignment: .trailing, spacing: 4) {
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
                shotButton
                recentToggle
            }
            Text(model.status)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(keysOffIdle ? Color(red: 1.0, green: 0.72, blue: 0.35) : Color.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 128)
                .allowsHitTesting(false)
            if model.showingRecent {
                recentList
            }
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
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            mover.fit(size)
        }
    }

    /// The dropdown arrow to the right of the controls: opens the recent replies.
    private var recentToggle: some View {
        Button(action: model.toggleRecent) {
            Image(systemName: model.showingRecent ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 12, height: controlSize * 2 + 4)
                .background(Capsule().fill(model.showingRecent ? Color.white.opacity(0.35) : Color.white.opacity(0.22)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(model.showingRecent ? "Hide recent replies" : "Recent replies - click one to hear it again")
        .accessibilityLabel(model.showingRecent ? "Hide recent replies" : "Show recent replies")
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.recent.isEmpty {
                Text("Nothing spoken yet")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
            ForEach(model.recent) { reply in
                Button {
                    model.replay(reply)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 7))
                        Text(Self.timeLabel(reply.time))
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                        Text(reply.text)
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(reply.text)
                .accessibilityLabel("Hear again: \(reply.text)")
            }
        }
        .frame(width: 230)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f
    }()

    /// Today's replies show the time; older ones the day as well.
    private static func timeLabel(_ time: Date) -> String {
        Calendar.current.isDateInToday(time) ? clock.string(from: time) : dayClock.string(from: time)
    }

    private var dictating: Bool {
        model.purpose == .dictate && model.mode != .idle
    }

    private var keysOffIdle: Bool {
        model.mode == .idle && model.status == "Keys off - click !"
    }

    private var badgeOrange: Color { Color(red: 0.90, green: 0.50, blue: 0.10) }

    /// Takes a screenshot of the display under the pointer. While shots are
    /// stacking it shows how many; without Screen Recording it shows "!" and
    /// clicking asks macOS again.
    private var shotButton: some View {
        control(
            "camera.fill",
            help: model.screenTrusted
                ? "Screenshot to Firstmate (or tap Right Shift); shots taken close together are sent as one message"
                : "Screenshots are off: macOS has not allowed this build Screen Recording. Click to allow it.",
            action: model.shotButton
        )
        .overlay(alignment: .topTrailing) {
            if !model.screenTrusted {
                badge(Text("!"), fill: badgeOrange)
                    .offset(x: 4, y: -4)
                    .allowsHitTesting(false)
            } else if model.shotCount > 0 {
                badge(Text("\(model.shotCount)"), fill: Color(red: 0.12, green: 0.45, blue: 0.85))
                    .offset(x: 4, y: -4)
                    .allowsHitTesting(false)
            }
        }
    }

    private func badge(_ label: Text, fill: Color) -> some View {
        label
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(.white)
            .frame(minWidth: 14, minHeight: 14)
            .background(Capsule().fill(fill))
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
                .background(Circle().fill(badgeOrange))
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
