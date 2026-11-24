import AppKit
import ApplicationServices
import Carbon
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
        if let folder = HomeLocation.repairTemporaryDirectory() {
            NSLog("DeskFloater: TMPDIR was not a usable folder; using %@", folder)
        }
        NSApp.setActivationPolicy(.accessory)
        guard let location = HomeLocation.resolve(
            environment: ProcessInfo.processInfo.environment,
            bundlePath: Bundle.main.bundlePath,
            currentDirectory: FileManager.default.currentDirectoryPath,
            isCodeRoot: HomeLocation.isCodeRoot
        ) else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "DeskFloater cannot find its Firstmate home"
            alert.informativeText = "Start it with bin/fm-desk-floater.sh in your Firstmate folder."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let model = FloaterModel(repoRoot: location.root, fmHome: location.home)
        let panel = FloaterPanel(model: model)
        panel.orderFrontRegardless()
        self.panel = panel

        let hotkeys = HotkeyMonitor()
        hotkeys.onTalkDown = { [weak model] in model?.hotkeyTalkBegan() }
        hotkeys.onTalkUp = { [weak model] in model?.hotkeyTalkEnded() }
        hotkeys.onTalkChord = { [weak model] in model?.hotkeyTalkChorded() }
        hotkeys.onDictateTap = { [weak model] in model?.toggleDictation() }
        hotkeys.onShotTap = { [weak model] in model?.takeShot() }
        hotkeys.onShotSkipped = { [weak model] reason in model?.shotSkipped(reason) }
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
        model.refreshVolume()
        model.startCaption()
        model.recoverRecordings()
        DispatchQueue.main.async {
            model.warmMicrophone()
        }
    }
}

/// Where the floater finds this home's scripts and state. The launcher passes
/// both; macOS "Quit & Reopen", Finder and login items start the app without
/// them and in "/", so the code root then comes from the bundle's own place in
/// the repo, <root>/desk-floater/.build/DeskFloater.app, and the home defaults
/// to that root as it does in the launcher.
enum HomeLocation {
    static func resolve(
        environment: [String: String],
        bundlePath: String,
        currentDirectory: String,
        isCodeRoot: (String) -> Bool
    ) -> (root: String, home: String)? {
        var root = nonEmpty(environment["FM_DESK_FLOATER_ROOT"])
        if root == nil {
            let build = URL(fileURLWithPath: bundlePath).standardizedFileURL.deletingLastPathComponent()
            let package = build.deletingLastPathComponent()
            let candidate = package.deletingLastPathComponent().path
            if build.lastPathComponent == ".build" && package.lastPathComponent == "desk-floater"
                && isCodeRoot(candidate) {
                root = candidate
            }
        }
        if root == nil && isCodeRoot(currentDirectory) {
            root = currentDirectory
        }
        guard let root else { return nil }
        return (root, nonEmpty(environment["FM_HOME"]) ?? root)
    }

    /// A Firstmate code root holds the scripts the floater runs.
    static func isCodeRoot(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(
            atPath: (path as NSString).appendingPathComponent("bin/fm-desk-voice.sh"))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// The temporary folder the floater and every helper it starts use, through
/// TMPDIR. A floater macOS starts by itself inherits whatever TMPDIR the login
/// session holds, and that can name a folder that no longer exists. Every
/// helper that makes a temporary file then fails: transcription and delivery
/// to the chat among them. So at launch the floater keeps TMPDIR only when it
/// is an existing folder it can write to, and otherwise points it at macOS's
/// own per-user temporary folder, then /tmp.
extension HomeLocation {
    /// True when <path> is an existing folder this process can create files in.
    static func isUsableTemporaryDirectory(_ path: String) -> Bool {
        var info = stat()
        guard !path.isEmpty, stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            return false
        }
        return access(path, W_OK | X_OK) == 0
    }

    /// The folder to use: <current> when usable, else the first usable of
    /// <systemDefault> and /tmp. Nil when none is usable, so the caller leaves
    /// TMPDIR as it is rather than swapping one broken folder for another.
    static func temporaryDirectory(
        current: String?,
        systemDefault: String?,
        isUsable: (String) -> Bool = HomeLocation.isUsableTemporaryDirectory
    ) -> String? {
        [current, systemDefault, "/tmp"]
            .compactMap { $0 }
            .first(where: isUsable)
    }

    /// macOS's per-user temporary folder, which TMPDIR normally names.
    static func systemTemporaryDirectory() -> String? {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// Points this process's TMPDIR, which every helper it starts inherits,
    /// at a usable folder. Returns the replacement, or nil when TMPDIR was
    /// already usable or nothing better exists.
    @discardableResult
    static func repairTemporaryDirectory() -> String? {
        let current = ProcessInfo.processInfo.environment["TMPDIR"]
        guard let folder = temporaryDirectory(current: current, systemDefault: systemTemporaryDirectory()),
              folder != current else {
            return nil
        }
        setenv("TMPDIR", folder, 1)
        return folder
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

/// Moves the floater with the pointer while its card is dragged, and resizes
/// it when the reply bubble opens, grows or closes. The top-right corner stays
/// put, so the buttons do not jump and the bubble drops down and to the left
/// of them.
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
/// limit, with no other key, click or modifier used while it was down. A key
/// with a typing guard also leaves taps close to typing alone: pressed within
/// `quiet` of the last key, or followed by a key within `settle` of its
/// release, it was a Shift brushed while typing rather than a tap. Such a key
/// also keeps why a lone press did not count (`takeSkip`), so the floater can
/// say so; a press used with another key, click or modifier is a shortcut and
/// leaves no reason.
struct TapKey {
    enum Skip: Equatable {
        case typing, held

        var message: String {
            switch self {
            case .typing: return "Shot skipped - typing"
            case .held: return "Shot skipped - held"
            }
        }
    }

    let keyCode: UInt16
    // Device-dependent modifier bit that tells the right-hand key from the left.
    let bit: UInt
    let flag: NSEvent.ModifierFlags
    let quiet: TimeInterval
    let settle: TimeInterval
    private var downAt: Date?
    private var chorded = false
    // Pressed within `quiet` of the last key.
    private var nearTyping = false
    private var lastKeyAt: Date?
    // A tap waiting out `settle`.
    private var pending: Date?
    private var skip: Skip?

    init(keyCode: UInt16, bit: UInt, flag: NSEvent.ModifierFlags,
         quiet: TimeInterval = 0, settle: TimeInterval = 0) {
        self.keyCode = keyCode
        self.bit = bit
        self.flag = flag
        self.quiet = quiet
        self.settle = settle
    }

    static let rightCommand = TapKey(keyCode: 54, bit: 0x10, flag: .command)
    static let rightShift = TapKey(keyCode: 60, bit: 0x04, flag: .shift, quiet: 1.5, settle: 0.5)

    /// A click while this key is down makes it part of a shortcut.
    mutating func chord() {
        if downAt != nil {
            chorded = true
        }
    }

    /// A key press: part of a shortcut while this key is down, and typing
    /// that a tap close to it belongs to.
    mutating func keyPressed(at now: Date) {
        lastKeyAt = max(lastKeyAt ?? now, now)
        if let tap = pending, now >= tap, now.timeIntervalSince(tap) < settle {
            pending = nil
            skip = .typing
        }
        chord()
    }

    /// Feeds one modifier change; true when it completes a lone tap. Modifiers
    /// in `allowed` may already be held without making the press a shortcut.
    mutating func update(keyCode: UInt16, flags: NSEvent.ModifierFlags, at now: Date,
                         allowed: NSEvent.ModifierFlags, limit: TimeInterval) -> Bool {
        guard keyCode == self.keyCode else {
            chord()
            return false
        }
        if flags.rawValue & bit != 0 {
            let others = NSEvent.ModifierFlags([.shift, .control, .option, .command, .function])
                .subtracting(flag)
                .subtracting(allowed)
            downAt = now
            chorded = !flags.intersection(others).isEmpty
            nearTyping = typed(within: quiet, before: now)
            return false
        }
        guard let started = downAt else { return false }
        downAt = nil
        guard !chorded else { return false }
        guard now.timeIntervalSince(started) < limit else {
            if settle > 0 {
                skip = .held
            }
            return false
        }
        guard !nearTyping else {
            skip = .typing
            return false
        }
        if settle > 0 {
            pending = now
        }
        return true
    }

    /// Called `settle` after a tap released at `tap`: true when it still
    /// stands, with no key pressed in between and no later tap replacing it.
    mutating func takeSettled(tap: Date) -> Bool {
        guard pending == tap else { return false }
        pending = nil
        return true
    }

    /// Why the last lone press did not count, once.
    mutating func takeSkip() -> Skip? {
        defer { skip = nil }
        return skip
    }

    private func typed(within interval: TimeInterval, before now: Date) -> Bool {
        guard interval > 0, let last = lastKeyAt else { return false }
        return now.timeIntervalSince(last) < interval
    }

    /// When an event happened, from its own timestamp (seconds since the Mac
    /// started), so events delivered in a late burst keep their real spacing.
    static func time(of event: NSEvent) -> Date {
        Date(timeIntervalSinceNow: event.timestamp - ProcessInfo.processInfo.systemUptime)
    }
}

/// Right Option held is push-to-talk. A key or click in the first moment of the
/// hold makes it a shortcut instead (Option-letter types a character,
/// Option-click is a click) and drops the hold. After that the captain is
/// talking: a key or a click, such as one that opens a menu, leaves the
/// recording running, and releasing the key still sends it.
struct TalkKey {
    enum Action: Equatable {
        case begin, deliver, drop
    }

    let shortcutWindow: TimeInterval
    private var downAt: Date?

    init(shortcutWindow: TimeInterval = 0.3) {
        self.shortcutWindow = shortcutWindow
    }

    var isDown: Bool { downAt != nil }

    /// Feeds a change of Right Option's own flag.
    mutating func update(down: Bool, at now: Date) -> Action? {
        if down && downAt == nil {
            downAt = now
            return .begin
        }
        if !down && downAt != nil {
            downAt = nil
            return .deliver
        }
        return nil
    }

    /// A key press or click while the key may be down.
    mutating func chord(at now: Date) -> Action? {
        guard let started = downAt, now.timeIntervalSince(started) < shortcutWindow else { return nil }
        downAt = nil
        return .drop
    }
}

/// Global keys: Right Option held is push-to-talk to Firstmate, a lone tap of
/// Right Command starts or finishes dictation, and a lone tap of Right Shift
/// away from typing takes a screenshot. Watching keys in other apps, and typing the dictated text
/// into them, both need the Accessibility permission. macOS ties that grant to
/// the app's signature, so an ad-hoc signed rebuild is untrusted again: it asks
/// once per build, and the keys-off badge asks again on demand.
@MainActor
final class HotkeyMonitor {
    var onTalkDown: (() -> Void)?
    var onTalkUp: (() -> Void)?
    var onTalkChord: (() -> Void)?
    var onDictateTap: (() -> Void)?
    var onShotTap: (() -> Void)?
    // Why a lone Right Shift press took no screenshot, for the status line.
    var onShotSkipped: ((String) -> Void)?
    var onTrustChanged: ((Bool) -> Void)?

    private static let rightOptionKey: UInt16 = 61
    // Device-dependent modifier bit that tells the right-hand key from the left.
    private static let rightOptionBit: UInt = 0x40
    private static let askedKey = "askedForAccessibilityBuild"
    private let tapLimit: TimeInterval = 0.5

    private var monitors: [Any] = []
    private var trustTimer: Timer?
    private var trusted = false
    private var talkKey = TalkKey()
    private var dictateKey = TapKey.rightCommand
    private var shotKey = TapKey.rightShift
    private var secureSkipShown = false

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

    /// Asks for the permission again and opens its Settings pane. An ad-hoc
    /// signed rebuild can still be listed there as switched on while macOS
    /// ignores the old grant, so the pane is where the captain switches it off and on.
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

    /// Identifies this exact build, so a rebuild macOS does not trust yet is
    /// asked about once more.
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
        let at = TapKey.time(of: event)
        if secureSkipShown && !IsSecureEventInputEnabled() {
            secureSkipShown = false
        }
        if event.type != .flagsChanged {
            // A key or click while a hotkey is held makes it a shortcut, not a
            // hotkey: Option-letter types a character, Command-click opens a link.
            // Right Option is a shortcut only in the first moment of its hold,
            // and that cancels the capture without sending anything.
            if talkKey.chord(at: at) == .drop {
                onTalkChord?()
            }
            if event.type == .keyDown {
                dictateKey.keyPressed(at: at)
                shotKey.keyPressed(at: at)
                reportShotSkip()
            } else {
                dictateKey.chord()
                shotKey.chord()
            }
            return
        }
        if event.keyCode == Self.rightOptionKey {
            let down = event.modifierFlags.rawValue & Self.rightOptionBit != 0
            switch talkKey.update(down: down, at: at) {
            case .begin:
                onTalkDown?()
            case .deliver:
                onTalkUp?()
            case .drop, nil:
                break
            }
        }
        if dictateKey.update(keyCode: event.keyCode, flags: event.modifierFlags, at: at,
                             allowed: [], limit: tapLimit) {
            onDictateTap?()
        }
        // Screenshots taken while Right Option is held join that voice message.
        if shotKey.update(keyCode: event.keyCode, flags: event.modifierFlags, at: at,
                          allowed: talkKey.isDown ? .option : [], limit: tapLimit) {
            shotTapped(at: at)
        }
        reportShotSkip()
    }

    private func reportShotSkip() {
        if let skip = shotKey.takeSkip(), skip != .held || !IsSecureEventInputEnabled() {
            onShotSkipped?(skip.message)
        }
    }

    /// A Right Shift tap becomes a screenshot only once typing has not resumed
    /// right after it. While secure typing is on (a password field, or a
    /// terminal's Secure Keyboard Entry) macOS hides key presses from the
    /// floater, so a capital letter would read as a lone Shift tap: no shot then,
    /// and the reason shows once until secure typing turns off again.
    private func shotTapped(at tap: Date) {
        guard !IsSecureEventInputEnabled() else {
            if !secureSkipShown {
                secureSkipShown = true
                onShotSkipped?("Shot skipped - secure")
            }
            return
        }
        Timer.scheduledTimer(withTimeInterval: shotKey.settle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shotKey.takeSettled(tap: tap) else { return }
                self.onShotTap?()
            }
        }
    }
}

/// The Screen Recording permission screenshots need. Like Accessibility, macOS
/// ties it to the app's signature: it is asked for once per build, checked every few
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

/// The terminal device of the frontmost tab of a terminal app, asked of the app
/// itself over Apple Events (the Automation permission). Only apps whose answer
/// has been checked against the real app are listed; any other app has no tab
/// to report, so dictation there is only pasted.
enum FrontTab {
    enum Answer {
        case tty(String)
        case denied
        case none
    }

    private static let scripts: [String: String] = [
        "com.apple.Terminal": "tell application id \"com.apple.Terminal\" to get tty of selected tab of front window",
    ]

    /// The front tab's terminal device only when the Automation permission is
    /// already granted, so it never asks the captain; nil otherwise.
    static func ttyIfAllowed(of app: NSRunningApplication) -> String? {
        guard let id = app.bundleIdentifier, scripts[id] != nil else { return nil }
        let target = NSAppleEventDescriptor(bundleIdentifier: id)
        guard let desc = target.aeDesc,
              AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard),
                                                    AEEventID(typeWildCard), false) == noErr,
              case .tty(let tty) = tty(of: app, seconds: 1) else { return nil }
        return tty
    }

    static func tty(of app: NSRunningApplication, seconds: Int = 3) -> Answer {
        guard let id = app.bundleIdentifier, let script = scripts[id] else { return .none }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "with timeout of \(seconds) seconds", "-e", script, "-e", "end timeout"]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return .none
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        proc.waitUntilExit()
        // -1743: the captain has not allowed the floater to control the app.
        if errText.contains("-1743") {
            return .denied
        }
        guard proc.terminationStatus == 0,
              let tty = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              tty.hasPrefix("/dev/") else {
            return .none
        }
        return .tty(tty)
    }
}

/// The app and window in front when the captain starts talking to Firstmate,
/// sent with the words as one "Front:" line (bin/fm-desk-voice.sh send --front)
/// so Firstmate knows what "this" or "here" means. Read with the permissions
/// the floater already has: the focused window's title over Accessibility,
/// else the window list's name, which Screen Recording reveals. With neither,
/// the app's name goes alone. For a terminal app whose front tab FrontTab can
/// name, `tty` lets the script leave the line out when that tab is Firstmate's
/// own chat.
struct Frontmost: Equatable, Sendable {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let title: String?
    var tty: String? = nil

    /// The value of `send --front`: name, bundle id and title, split by "|".
    var argument: String {
        [name, bundleID ?? "", title ?? ""].joined(separator: "|")
    }

    /// App <app> and its front window, or nil when <app> is the floater
    /// itself. It asks the app over Accessibility and Apple Events, so it runs
    /// off the main actor.
    static func read(_ app: NSRunningApplication) -> Frontmost? {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let name = app.localizedName, !name.isEmpty else { return nil }
        let pid = app.processIdentifier
        return Frontmost(pid: pid, name: name, bundleID: app.bundleIdentifier,
                         title: focusedTitle(of: pid) ?? listedTitle(of: pid),
                         tty: FrontTab.ttyIfAllowed(of: app))
    }

    /// The focused window's title over Accessibility, asked with a short
    /// timeout so a busy app never holds up the press.
    private static func focusedTitle(of pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let element = window as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return nonEmpty(title as? String)
    }

    /// The name of the app's frontmost ordinary window in the window list,
    /// which macOS shows only with Screen Recording allowed.
    private static func listedTitle(of pid: pid_t) -> String? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if let name = nonEmpty(window[kCGWindowName as String] as? String) {
                return name
            }
        }
        return nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
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
    /// The app and window in front when the held words began.
    private(set) var front: Frontmost?
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
    /// The first held words' front window is the message's.
    mutating func hold(_ text: String, front: Frontmost? = nil) -> Bool {
        if let held = transcript {
            transcript = held + " " + text
            self.front = self.front ?? front
            return true
        }
        guard count > 0 else { return false }
        transcript = text
        self.front = front
        return true
    }

    func ready(at now: Date) -> Bool {
        !isEmpty && inFlight == 0 && now >= dueAt
    }

    /// Empties the stack, returning the message it held.
    mutating func take() -> (text: String?, images: [String], front: Frontmost?) {
        defer {
            transcript = nil
            front = nil
            shots = []
        }
        return (transcript, shots, front)
    }

    private mutating func touch(_ now: Date) {
        lastActivity = max(lastActivity ?? now, now)
    }
}

/// The spoken voice's level, as `bin/fm-speak.sh --volume` keeps it: a whole
/// percentage of the Mac's own output volume, where 100 is as loud as
/// everything else and anything above it is extra gain for the voice alone.
enum VoiceVolume {
    static let range = 0...200
    static let standard = 100

    static func clamp(_ level: Int) -> Int {
        min(max(level, range.lowerBound), range.upperBound)
    }

    /// Reads `--volume`'s output; anything else is not a level.
    static func parse(_ out: String?) -> Int? {
        guard let text = out?.trimmingCharacters(in: .whitespacesAndNewlines),
              let level = Int(text), range.contains(level) else {
            return nil
        }
        return level
    }
}

/// The voice-volume steps the floater's right-click menu offers; any other
/// level, such as one set on the web page, is kept and shown as it is.
extension VoiceVolume {
    static let steps = [25, 50, 75, 100, 125, 150, 200]
}

/// One reply from the speak-out history, as `bin/fm-speak.sh --history` lists
/// it, with the words written for the eye that `--caption` and `--full` read.
struct Reply: Identifiable, Equatable {
    let id: Int
    let time: Date
    /// The spoken line.
    let text: String
    /// The bubble's caption: the outcome and the ask, never a voice pointer.
    var eye: String
    /// The whole written reply the bubble opens to.
    var full: String

    init(id: Int, time: Date, text: String, eye: String? = nil, full: String? = nil) {
        self.id = id
        self.time = time
        self.text = text
        self.eye = eye ?? text
        self.full = full ?? eye ?? text
    }
}

/// Firstmate's offer to take one easy-to-undo step on the screen, as
/// `bin/fm-desk-offer.sh status` prints it.
struct Offer: Equatable, Decodable {
    enum State: String, Decodable {
        case open, expired, accepted, working, stopping, none
    }

    let id: String
    let text: String
    let state: State

    /// The offer still belongs on the bubble: waiting for a tap, or work the
    /// captain set going that has not finished.
    var isActive: Bool { [.open, .accepted, .working, .stopping].contains(state) }
    /// Firstmate is acting on it, so Stop is shown.
    var isActing: Bool { [.accepted, .working].contains(state) }

    /// Reads `status`; nil for no offer, or for anything that is not one.
    static func parse(_ out: String?) -> Offer? {
        guard let data = out?.data(using: .utf8),
              let offer = try? JSONDecoder().decode(Offer.self, from: data),
              offer.state != .none else { return nil }
        return offer
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

    /// Where a capture's transcript goes: to Firstmate, or typed into the
    /// focused text box. Dictated text reaches Firstmate only when that text
    /// box is Firstmate's own chat.
    enum Purpose {
        case firstmate
        case dictate
    }

    @Published var mode: Mode = .idle
    @Published var purpose: Purpose = .firstmate
    @Published var status: String = "Hold to talk"
    @Published var muted = false
    /// The spoken voice's level as a percentage of the system volume.
    @Published var voiceVolume = VoiceVolume.standard
    /// Firstmate's newest reply, shown as a caption beside the floater whether
    /// the voice is muted or not; nil when there is none to show.
    @Published var caption: Reply?
    @Published var captionExpanded = false
    /// A line is playing now, so the bubble shows Stop.
    @Published var speaking = false
    /// Firstmate's current offer to take a step on the screen.
    @Published var offer: Offer?
    /// The offer, in the state it had, that the captain closed the bubble on.
    @Published var dismissedOffer: Offer?
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
    /// Captures are recorded here, in the home's private state, so a recording
    /// outlives a floater that stops before sending it.
    let recordingDir: String
    // Echo-cancelled, so a reply playing on the speakers stays out of the
    // message while it keeps playing. See VoiceCapture.
    private let capture = VoiceCapture()
    private var recordURL: URL?
    /// The app and window in front when the current talk began, read in the
    /// background so it never delays the recording.
    private var captureFront: Task<Frontmost?, Never>?
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
    // The recordings of the words held in the stack, kept until they are sent.
    private var heldAudio: [URL] = []

    // Saved talk-to-Firstmate recordings waiting for an automatic retry, by
    // path, with the attempts each has had. See Recording.
    private(set) var retrying: [String: Int] = [:]

    // The caption follows bin/fm-speak.sh's reply history: a change to its
    // folder is read through `--history`. Replies kept before the floater
    // started are never shown as new.
    private let historyDir: String
    private var historyStamp: Date?
    private var captionSeen: Int?
    private var captionTimer: Timer?
    /// Bumped whenever the caption changes, so an older hide timer lets a
    /// newer caption be.
    private var captionTurn = 0
    /// How long a caption stays up unless it is expanded, or held up by an
    /// offer, work under way or a line still playing.
    nonisolated static let captionShown: TimeInterval = 15

    // The offer follows bin/fm-desk-offer.sh's record, read through `status`
    // when it changes, after a new reply (which can expire it), and now and
    // then for its time limit.
    private let offerFile: String
    private var offerStamp: Date?
    private var offerTicks = 0
    private var speakingTimer: Timer?
    private var speakingAsked = false

    // The Show button: held, it is talk with a picture taken as it went down.
    private var showPressAt: Date?
    private var showTalking = false

    init(repoRoot: String, fmHome: String) {
        self.repoRoot = repoRoot
        self.fmHome = fmHome
        recordingDir = (fmHome as NSString).appendingPathComponent("state/desk-voice/recording")
        historyDir = (fmHome as NSString).appendingPathComponent("state/speak-history")
        offerFile = (fmHome as NSString).appendingPathComponent("state/desk-voice/offer.json")
        muteTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshMute()
                self?.refreshVolume()
            }
        }
    }

    static let savedRetrying = "Saved - retrying"
    static let micSilent = "Mic silent - not sent"

    var idleStatus: String {
        if stack.transcript != nil {
            return "Adding shots…"
        }
        if shotCount > 0 {
            return shotCount == 1 ? "1 shot stacked" : "\(shotCount) shots stacked"
        }
        if !retrying.isEmpty {
            return Self.savedRetrying
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

    /// Show went down: the picture of the display under the pointer is taken
    /// now, and the microphone opens in case the captain speaks while holding.
    func showPressBegan() {
        guard showPressAt == nil else { return }
        showPressAt = Date()
        guard screenTrusted else { return }
        takeShot()
        if mode == .idle {
            begin(.firstmate)
            showTalking = true
            pressStartedAt = Date()
        }
    }

    /// Show came up: a tap sends the picture alone, as the stack does; a hold
    /// sends the words spoken meanwhile with it. Without Screen Recording the
    /// press asks macOS again instead.
    func showPressEnded() {
        let held = showPressAt.map { Date().timeIntervalSince($0) } ?? 0
        showPressAt = nil
        guard screenTrusted else {
            onFixScreen?()
            return
        }
        guard showTalking else { return }
        showTalking = false
        switch mode {
        case .starting:
            cancelCapture()
        case .recording where purpose == .firstmate:
            if held < tapWindow {
                cancelCapture()
            } else {
                stopAndDeliver()
            }
        case .recording, .idle, .busy:
            break
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
            let (path, error) = Self.shoot(repoRoot: repoRoot, fmHome: fmHome, display: display)
            await MainActor.run {
                self.stack.shotFinished(path, at: Date())
                self.shotsChanged()
                if path == nil {
                    self.flash(error.map { "Shot failed - \($0)" } ?? "Shot failed", for: 5)
                }
                self.scheduleFlush()
            }
        }
    }

    /// A Right Shift press that took no screenshot, with the reason.
    func shotSkipped(_ reason: String) {
        flash(reason, for: 3)
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
        let (text, images, front) = stack.take()
        let audio = heldAudio
        heldAudio = []
        shotsChanged()
        if mode == .idle {
            if text != nil {
                status = "Delivering…"
            } else {
                status = images.count == 1 ? "Sending 1 shot…" : "Sending \(images.count) shots…"
            }
        }
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            let outcome = Self.deliver(repoRoot: repoRoot, fmHome: fmHome, text: text, images: images, front: front)
            await MainActor.run {
                self.delivered(outcome, audio: audio)
            }
        }
    }

    /// After a talk-to-Firstmate message went (or failed to go): its recordings
    /// are removed once the words are delivered, and kept to be tried again
    /// when they were not.
    private func delivered(_ outcome: String?, audio: [URL], finishing: Bool = false) {
        guard outcome != nil || audio.isEmpty else {
            for url in audio {
                keepForRetry(url, purpose: .firstmate, reason: "delivery failed", finishing: finishing)
            }
            return
        }
        for url in audio {
            try? FileManager.default.removeItem(at: url)
        }
        let status = outcome ?? "Deliver failed"
        if finishing {
            finish(status: status)
        } else {
            flash(status)
        }
    }

    /// A transcribed talk-to-Firstmate message: sent at once when nothing is
    /// stacked, otherwise held until the stack window closes and sent with the
    /// shots. The floater is free meanwhile, so another talk joins the same message.
    private func voiceTranscribed(_ text: String, audio: URL, front: Frontmost?) {
        guard stack.hold(text, front: front) else {
            status = "Delivering…"
            Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
                let outcome = Self.deliver(repoRoot: repoRoot, fmHome: fmHome, text: text, images: [], front: front)
                await MainActor.run {
                    self.delivered(outcome, audio: [audio], finishing: true)
                }
            }
            return
        }
        heldAudio.append(audio)
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

    // MARK: dictation (a tap of Right Command)

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

    /// Stop on the bubble: cuts the line playing now and, while Firstmate is
    /// acting on an offer, asks it to stop.
    func stopAll() {
        runSpeak(["--stop"]) { ok in ok ? "Stopped" : "Stop failed" }
        if let offer, offer.isActing {
            answerOffer("stop", offer)
        }
    }

    /// "Hear again" under a reply: speaks that reply again.
    func hearAgain() {
        guard let reply = caption else { return }
        guard !muted else {
            if mode == .idle {
                finish(status: "Voice muted")
            }
            return
        }
        runSpeak(["--replay", String(reply.id)]) { ok in ok ? "Repeating" : "No longer kept" }
        watchSpeaking()
    }

    // MARK: reply caption

    /// Starts following the reply history for the caption.
    func startCaption() {
        historyStamp = Self.modified(historyDir)
        readCaption(initial: true)
        offerStamp = Self.modified(offerFile)
        readOffer()
        captionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkHistory()
                self?.checkOffer()
            }
        }
        speakingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSpeaking() }
        }
    }

    private func checkHistory() {
        let stamp = Self.modified(historyDir)
        guard stamp != historyStamp else { return }
        historyStamp = stamp
        readCaption(initial: false)
        readOffer()
        // A reply's text is written just after its folder appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.readCaption(initial: false)
        }
    }

    private func readCaption(initial: Bool) {
        Task.detached(priority: .utility) { [repoRoot, fmHome] in
            let out = Self.speak(repoRoot: repoRoot, fmHome: fmHome, args: ["--history"]) ?? ""
            var newest = Self.parseHistory(out).first
            if !initial, let found = newest {
                let number = String(found.id)
                newest = Reply(id: found.id, time: found.time, text: found.text,
                               eye: Self.kept(Self.speak(repoRoot: repoRoot, fmHome: fmHome, args: ["--caption", number])),
                               full: Self.kept(Self.speak(repoRoot: repoRoot, fmHome: fmHome, args: ["--full", number])))
            }
            let reply = newest
            await MainActor.run {
                self.historyRead(reply, initial: initial)
            }
        }
    }

    nonisolated private static func kept(_ out: String?) -> String? {
        guard let text = out?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private func historyRead(_ newest: Reply?, initial: Bool) {
        if initial {
            captionSeen = max(captionSeen ?? 0, newest?.id ?? 0)
            return
        }
        guard let newest, newest.id > (captionSeen ?? 0) else { return }
        captionSeen = newest.id
        caption = newest
        captionExpanded = false
        scheduleCaptionHide()
        watchSpeaking()
    }

    func dismissCaption() {
        captionTurn += 1
        caption = nil
        captionExpanded = false
        if let offer, offer.isActive {
            dismissedOffer = offer
        }
    }

    /// The offer the bubble shows, unless the captain closed the bubble on it
    /// in this same state.
    var shownOffer: Offer? {
        guard let offer, offer.isActive, offer != dismissedOffer else { return nil }
        return offer
    }

    var bubbleShown: Bool { caption != nil || shownOffer != nil }

    /// Something on the bubble still means something, so it stays up.
    private var holdsBubble: Bool { speaking || shownOffer != nil }

    // MARK: the offer (Do it / Not now)

    func doIt() {
        guard let offer = shownOffer, offer.state == .open else { return }
        answerOffer("do", offer)
    }

    func notNow() {
        guard let offer = shownOffer, offer.state == .open else { return }
        answerOffer("not-now", offer)
    }

    /// A tap travels as a line to Firstmate through bin/fm-desk-offer.sh; the
    /// floater itself never acts.
    private func answerOffer(_ kind: String, _ offer: Offer) {
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            let out = Self.run(bin: (repoRoot as NSString).appendingPathComponent("bin/fm-desk-offer.sh"),
                               args: ["answer", kind, offer.id], env: ["FM_HOME": fmHome])
            await MainActor.run {
                if self.mode == .idle {
                    switch kind {
                    case "not-now": self.flash(out == nil ? "Offer gone" : "Not now")
                    default: self.flash(out == nil ? "Not sent" : SendOutcome.status(out) ?? "Sent")
                    }
                }
                self.readOffer()
            }
        }
    }

    private func checkOffer() {
        offerTicks += 1
        let stamp = Self.modified(offerFile)
        guard stamp != offerStamp || offerTicks % 20 == 0 else { return }
        offerStamp = stamp
        readOffer()
    }

    func readOffer() {
        Task.detached(priority: .utility) { [repoRoot, fmHome] in
            let out = Self.run(bin: (repoRoot as NSString).appendingPathComponent("bin/fm-desk-offer.sh"),
                               args: ["status"], env: ["FM_HOME": fmHome])
            let offer = Offer.parse(out)
            await MainActor.run {
                guard self.offer != offer else { return }
                let held = self.holdsBubble
                self.offer = offer
                if self.dismissedOffer != nil && self.dismissedOffer != offer {
                    self.dismissedOffer = nil
                }
                if held && !self.holdsBubble && self.caption != nil {
                    self.scheduleCaptionHide()
                }
                self.watchSpeaking()
            }
        }
    }

    // MARK: speaking (Stop shows only while a line plays)

    /// Asks once now whether a line is playing, rather than waiting a tick.
    private func watchSpeaking() {
        checkSpeaking(force: true)
    }

    private func checkSpeaking(force: Bool = false) {
        guard !speakingAsked, force || bubbleShown || speaking else { return }
        speakingAsked = true
        Task.detached(priority: .utility) { [repoRoot, fmHome] in
            let out = Self.speak(repoRoot: repoRoot, fmHome: fmHome, args: ["--speaking"])
            let now = out?.trimmingCharacters(in: .whitespacesAndNewlines) == "speaking"
            await MainActor.run {
                self.speakingAsked = false
                if self.speaking != now {
                    self.speaking = now
                }
            }
        }
    }

    /// An expanded caption stays until it is dismissed or collapsed again.
    func toggleCaptionExpanded() {
        captionExpanded.toggle()
        captionTurn += 1
        if !captionExpanded {
            scheduleCaptionHide()
        }
    }

    private func scheduleCaptionHide(after delay: TimeInterval = FloaterModel.captionShown) {
        captionTurn += 1
        let turn = captionTurn
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.captionTurn == turn, !self.captionExpanded else { return }
            if self.holdsBubble {
                self.scheduleCaptionHide(after: 2)
                return
            }
            self.caption = nil
        }
    }

    nonisolated private static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Reads `<number> TAB <epoch> TAB <text>` lines, newest first.
    nonisolated private static func parseHistory(_ out: String) -> [Reply] {
        out.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard cols.count == 3, let id = Int(cols[0]), let epoch = TimeInterval(cols[1]) else {
                return nil
            }
            return Reply(id: id, time: Date(timeIntervalSince1970: epoch), text: String(cols[2]))
        }
    }

    func toggleMute() {
        let wasMuted = muted
        muted.toggle()
        runSpeak([wasMuted ? "--unmute" : "--mute"]) { ok in
            ok ? (wasMuted ? "Voice on" : "Voice muted") : "Mute failed"
        }
    }

    func refreshVolume() {
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            let level = VoiceVolume.parse(Self.speak(repoRoot: repoRoot, fmHome: fmHome, args: ["--volume"]))
            await MainActor.run {
                if let level, self.voiceVolume != level {
                    self.voiceVolume = level
                }
            }
        }
    }

    /// Keeps the level for the next spoken line; the system volume is never
    /// touched.
    func setVoiceVolume(_ level: Int) {
        let level = VoiceVolume.clamp(level)
        voiceVolume = level
        runSpeak(["--volume", String(level)]) { ok in
            ok ? "Voice at \(level)%" : "Volume not saved"
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
        // What the captain was looking at as they started talking.
        captureFront = nil
        if purpose == .firstmate, let app = NSWorkspace.shared.frontmostApplication {
            captureFront = Task.detached(priority: .userInitiated) { Frontmost.read(app) }
        }
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
            let url = URL(fileURLWithPath: recordingDir)
                .appendingPathComponent(Recording.fileName(purpose: purpose == .dictate ? "dictate" : "firstmate"))
            do {
                try FileManager.default.createDirectory(
                    atPath: recordingDir, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try capture.start(writingTo: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                mode = .idle
                status = "Record error"
                return
            }
            guard mode == .starting else {
                capture.stop()
                try? FileManager.default.removeItem(at: url)
                return
            }
            recordURL = url
            mode = .recording
            status = listeningStatus
        }
    }

    private func cancelCapture() {
        captureFront = nil
        latched = false
        fromHotkey = false
        pressStartedAt = nil
        capture.stop()
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
        guard let url = recordURL else {
            capture.stop()
            mode = .idle
            self.purpose = .firstmate
            status = idleStatus
            return
        }
        recordURL = nil
        let front = captureFront
        captureFront = nil
        mode = .busy
        status = "Transcribing…"
        // The last words are still arriving as the key comes up; the capture
        // keeps recording for a moment before the file is closed.
        capture.finish { [self] in
            transcribeAndDeliver(url, purpose: purpose, front: front)
        }
    }

    func transcribeAndDeliver(_ url: URL, purpose: Purpose, front talkFront: Task<Frontmost?, Never>? = nil) {
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            // Near silence holds no words to send or to retry: say so at once
            // rather than saving it and retrying it.
            if Recording.isSilent(url) {
                try? FileManager.default.removeItem(at: url)
                await MainActor.run {
                    self.finish(status: Self.micSilent, for: 6)
                }
                return
            }
            let transcript = Self.transcribe(repoRoot: repoRoot, fmHome: fmHome, audio: url)
            let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                // Nothing came back. The audio stays until its words are
                // delivered, unless it is too short to hold any.
                let failed = transcript == nil
                if Recording.keep(failed: failed, duration: Recording.duration(of: url)) {
                    await MainActor.run {
                        self.keepForRetry(url, purpose: purpose,
                                          reason: failed ? "transcription failed" : "no speech heard",
                                          finishing: true)
                    }
                } else {
                    try? FileManager.default.removeItem(at: url)
                    await MainActor.run {
                        self.finish(status: failed ? "Transcribe failed" : "No speech")
                    }
                }
                return
            }
            if purpose == .dictate {
                // Once transcribed, dictation is always typed, sent or left on
                // the clipboard below.
                try? FileManager.default.removeItem(at: url)
            }
            switch purpose {
            case .dictate:
                // Dictating into Firstmate's own chat sends it, as talking to
                // Firstmate does; anywhere else the text is only pasted.
                let front = await MainActor.run { NSWorkspace.shared.frontmostApplication }
                var denied = false
                if let front {
                    switch FrontTab.tty(of: front) {
                    case .tty(let tty):
                        if let sent = Self.sendIfInFront(repoRoot: repoRoot, fmHome: fmHome, text: text,
                                                         app: front.processIdentifier, tty: tty) {
                            await MainActor.run {
                                self.finish(status: sent)
                            }
                            return
                        }
                    case .denied:
                        denied = true
                    case .none:
                        break
                    }
                }
                await MainActor.run { [denied] in
                    let typed = Paster.paste(text)
                    if !typed {
                        self.finish(status: "Copied - press ⌘V")
                    } else {
                        self.finish(status: denied ? "Typed, not sent - allow Terminal" : "Typed")
                    }
                }
            case .firstmate:
                let front = await talkFront?.value
                await MainActor.run {
                    self.voiceTranscribed(text, audio: url, front: front)
                }
            }
        }
    }

    // MARK: recordings kept until delivered

    /// Saves a recording whose words did not reach their destination to the
    /// home's unsent folder and, for talk to Firstmate, retries it on
    /// Recording.retryDelays. A dictation stays saved for a manual retry with
    /// `bin/fm-desk-voice.sh retry`. Should the save itself fail, the audio
    /// stays in the recording folder, where the next launch finds it.
    private func keepForRetry(_ url: URL, purpose: Purpose, reason: String, finishing: Bool) {
        let name = purpose == .dictate ? "dictate" : "firstmate"
        let retries = purpose == .firstmate
        let message = retries ? Self.savedRetrying : "Saved, not sent"
        if finishing {
            finish(status: message, for: 6)
        } else {
            flash(message, for: 6)
        }
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            let saved = Self.keep(repoRoot: repoRoot, fmHome: fmHome, audio: url, purpose: name, reason: reason)
            await MainActor.run {
                guard let saved, retries else {
                    self.flash("Saved, not sent", for: 6)
                    return
                }
                self.scheduleRetry(saved, attempts: 1)
            }
        }
    }

    private func scheduleRetry(_ path: String, attempts: Int, after wait: TimeInterval? = nil) {
        guard let delay = wait ?? Recording.retryDelay(afterAttempts: attempts) else {
            retrying[path] = nil
            if mode == .idle {
                status = idleStatus
            }
            flash("Saved, not sent", for: 6)
            return
        }
        retrying[path] = attempts
        if mode == .idle {
            status = idleStatus
        }
        Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.retry(path) }
        }
    }

    private func retry(_ path: String) {
        let attempts = retrying[path] ?? 1
        Task.detached(priority: .utility) { [repoRoot, fmHome] in
            let result = Self.retryRecording(repoRoot: repoRoot, fmHome: fmHome, path: path)
            await MainActor.run {
                switch result {
                case .delivered(let status):
                    self.retried(path, status: status)
                case .unsent(let made):
                    self.scheduleRetry(path, attempts: made)
                case .busy:
                    self.scheduleRetry(path, attempts: attempts, after: Recording.busyDelay)
                case .gone:
                    self.retried(path, status: nil)
                case nil:
                    self.scheduleRetry(path, attempts: attempts + 1)
                }
            }
        }
    }

    private func retried(_ path: String, status message: String?) {
        retrying[path] = nil
        if mode == .idle {
            status = idleStatus
        }
        if let message {
            flash(message, for: 6)
        }
    }

    /// At launch: saves any recording a stopped floater left in the recording
    /// folder, then resumes the automatic retries of saved talk-to-Firstmate
    /// recordings that still have some left.
    func recoverRecordings() {
        Task.detached(priority: .utility) { [repoRoot, fmHome, recordingDir] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: recordingDir)) ?? []
            for name in names where name.hasSuffix(".wav") {
                let url = URL(fileURLWithPath: recordingDir).appendingPathComponent(name)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                // A file still being written belongs to a capture under way.
                if let modified = attributes?[.modificationDate] as? Date,
                   Date().timeIntervalSince(modified) < 10 {
                    continue
                }
                if !Recording.isSilent(url),
                   Recording.keep(failed: true, duration: Recording.duration(of: url)) {
                    _ = Self.keep(repoRoot: repoRoot, fmHome: fmHome, audio: url,
                                  purpose: Recording.purpose(ofFileName: name),
                                  reason: "the floater stopped before it was sent")
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let listing = Self.run(bin: (repoRoot as NSString).appendingPathComponent("bin/fm-desk-voice.sh"),
                                   args: ["recordings"], env: ["FM_HOME": fmHome]) ?? ""
            let pending: [(String, Int)] = listing.split(separator: "\n").compactMap { line in
                let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard cols.count >= 3, cols[1] == "firstmate", let attempts = Int(cols[2]),
                      Recording.retryDelay(afterAttempts: attempts) != nil else { return nil }
                return (String(cols[0]), attempts)
            }
            await MainActor.run {
                for (path, attempts) in pending where self.retrying[path] == nil {
                    self.scheduleRetry(path, attempts: attempts)
                }
            }
        }
    }

    private func finish(status: String, for seconds: TimeInterval? = nil) {
        mode = .idle
        purpose = .firstmate
        flash(status, for: seconds)
    }

    /// Shows a short outcome on the status line while nothing is being captured.
    /// A message saved rather than sent stays up longer, so it is not missed.
    private func flash(_ message: String, for seconds: TimeInterval? = nil) {
        guard mode == .idle else { return }
        status = message
        let shown = seconds ?? (message == SendOutcome.savedForFirstmate ? 6 : 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + shown) {
            if self.mode == .idle && self.status == message {
                self.status = self.idleStatus
            }
        }
    }

    /// Builds the capture engine ahead of the first press when the microphone
    /// is already allowed, so the first words of the first message are
    /// recorded too. See VoiceCapture.
    func warmMicrophone() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        try? capture.warm()
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
    /// `front` adds the "Front:" line, which the script leaves out when the
    /// front tab it names shows Firstmate's own chat.
    nonisolated private static func deliver(repoRoot: String, fmHome: String, text: String?, images: [String],
                                            front: Frontmost?) -> String? {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-desk-voice.sh")
        var args = ["send", "--source", "desk-floater"]
        if let front {
            args += ["--front", front.argument]
            if let tty = front.tty {
                args += ["--front-pid", String(front.pid), "--front-tab-tty", tty]
            }
        }
        for image in images {
            args += ["--image", image]
        }
        args.append("--")
        if let text {
            args.append(text)
        }
        return SendOutcome.status(run(bin: bin, args: args, env: ["FM_HOME": fmHome]))
    }

    /// Sends dictated text to Firstmate when the text box with the cursor is
    /// Firstmate's own chat: the frontmost tab <tty> of app <app> shows it.
    /// Returns the status to show, or nil when the chat is not in front (or
    /// the check failed), so the caller pastes the text instead.
    nonisolated private static func sendIfInFront(repoRoot: String, fmHome: String, text: String,
                                                  app: pid_t, tty: String) -> String? {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-desk-voice.sh")
        let args = ["send", "--front-app", String(app), "--front-tty", tty,
                    "--source", "desk-floater-dictation", "--", text]
        guard let out = run(bin: bin, args: args, env: ["FM_HOME": fmHome]),
              !out.hasPrefix("not-in-front") else {
            return nil
        }
        return SendOutcome.status(out)
    }

    /// Saves a recording to the home's unsent folder; the saved path, or nil.
    nonisolated private static func keep(repoRoot: String, fmHome: String, audio: URL,
                                         purpose: String, reason: String) -> String? {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-desk-voice.sh")
        let path = run(bin: bin, args: ["keep", "--purpose", purpose, "--reason", reason, "--", audio.path],
                       env: ["FM_HOME": fmHome])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    /// Transcribes and delivers one saved recording again.
    nonisolated private static func retryRecording(repoRoot: String, fmHome: String, path: String) -> RetryResult? {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-desk-voice.sh")
        return run(bin: bin, args: ["retry", path], env: ["FM_HOME": fmHome])
            .flatMap { RetryResult.parse($0) }
    }

    /// The reason a script such as `fm-desk-voice.sh shot` gives on failure:
    /// its last message line, without the script's name.
    nonisolated static func lastMessage(from stderr: String) -> String? {
        guard let line = stderr.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty }) else { return nil }
        guard let colon = line.range(of: ": "), line.hasPrefix("fm-") else { return line }
        return String(line[colon.upperBound...])
    }

    /// Captures one display to this home's screenshot folder: the image's
    /// path, or nil and the capture's own reason when it failed.
    nonisolated private static func shoot(repoRoot: String, fmHome: String, display: Int?) -> (String?, String?) {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-desk-voice.sh")
        var args = ["shot"]
        if let display {
            args += ["--display", String(display)]
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["FM_HOME"] = fmHome
        proc.environment = environment
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return (nil, "cannot start \((bin as NSString).lastPathComponent)")
        }
        // Both outputs are a line or two, so reading one to the end first cannot stall.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        FileHandle.standardError.write(errData)
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if proc.terminationStatus == 0 && !path.isEmpty {
            return (path, nil)
        }
        return (nil, lastMessage(from: String(data: errData, encoding: .utf8) ?? ""))
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

/// Option B, "Quiet": two round buttons, Talk and a smaller Show, with the
/// status line under them on a small paper card, and the reply bubble below.
/// The rare controls are on the bubble, only while they mean something: Stop
/// while a line plays or Firstmate acts on an offer, the speaker mark while a
/// line plays or the voice is muted, and Hear again under a reply. Voice volume
/// and mute are on a right-click of the card; recent replies are on the web page.
struct FloaterView: View {
    @ObservedObject var model: FloaterModel
    let mover: WindowMover

    private let talkSize: CGFloat = 36
    private let showSize: CGFloat = 27
    private let statusWidth: CGFloat = 112

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            cluster
            if model.bubbleShown {
                bubble
            }
        }
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            mover.fit(size)
        }
    }

    // MARK: colours

    // The calm paper card: light paper with dark ink, or the reverse in Dark
    // Mode, so the floater reads as part of the desk rather than as a control panel.
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static let paper = adaptive(
        light: NSColor(srgbRed: 1.0, green: 0.992, blue: 0.973, alpha: 1),
        dark: NSColor(srgbRed: 0.129, green: 0.137, blue: 0.122, alpha: 1))
    private static let ink = adaptive(
        light: NSColor(srgbRed: 0.137, green: 0.129, blue: 0.114, alpha: 1),
        dark: NSColor(srgbRed: 0.922, green: 0.910, blue: 0.882, alpha: 1))
    private static let soft = adaptive(
        light: NSColor(srgbRed: 0.420, green: 0.400, blue: 0.361, alpha: 1),
        dark: NSColor(srgbRed: 0.635, green: 0.616, blue: 0.573, alpha: 1))
    private static let line = adaptive(
        light: NSColor(srgbRed: 0.890, green: 0.867, blue: 0.816, alpha: 1),
        dark: NSColor(srgbRed: 0.200, green: 0.208, blue: 0.184, alpha: 1))
    private static let wash = adaptive(
        light: NSColor(srgbRed: 0.957, green: 0.941, blue: 0.914, alpha: 1),
        dark: NSColor(srgbRed: 0.173, green: 0.184, blue: 0.165, alpha: 1))
    private static let blue = Color(red: 0.16, green: 0.43, blue: 0.70)
    private static let stopRed = Color(red: 0.72, green: 0.25, blue: 0.20)
    private static let orange = Color(red: 0.90, green: 0.50, blue: 0.10)
    private static let warnInk = adaptive(
        light: NSColor(srgbRed: 0.70, green: 0.36, blue: 0.05, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.72, blue: 0.35, alpha: 1))

    // MARK: the resting card

    private var cluster: some View {
        VStack(spacing: 5) {
            HStack(alignment: .center, spacing: 10) {
                talkButton
                showButton
            }
            Text(model.status)
                .help(model.status)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(keysOffIdle ? Self.warnInk : Self.soft)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
                .frame(width: statusWidth)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Self.paper)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { _ in mover.drag() }
                        .onEnded { _ in mover.end() }
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Self.line)
                .allowsHitTesting(false)
        )
        .contextMenu { voiceMenu }
    }

    /// The right-click menu: the voice's level beside everything else on the
    /// Mac (100% is the system volume) and mute. The web page's Settings set
    /// the same level.
    private var voiceMenu: some View {
        Group {
            Picker("Voice volume", selection: Binding(
                get: { model.voiceVolume },
                set: { model.setVoiceVolume($0) }
            )) {
                ForEach(volumeChoices, id: \.self) { level in
                    Text(level == VoiceVolume.standard ? "\(level)% (system volume)" : "\(level)%").tag(level)
                }
            }
            Button(model.muted ? "Unmute voice" : "Mute voice", action: model.toggleMute)
        }
    }

    private var volumeChoices: [Int] {
        VoiceVolume.steps.contains(model.voiceVolume)
            ? VoiceVolume.steps
            : (VoiceVolume.steps + [model.voiceVolume]).sorted()
    }

    private var keysOffIdle: Bool {
        model.mode == .idle && model.status == "Keys off - click !"
    }

    private var talkColor: Color {
        if model.purpose == .dictate && model.mode != .idle {
            return Color(red: 0.55, green: 0.30, blue: 0.85)
        }
        switch model.mode {
        case .idle: return Self.blue
        case .starting: return Color(red: 0.85, green: 0.55, blue: 0.20)
        case .recording: return Color(red: 0.82, green: 0.22, blue: 0.20)
        case .busy: return Color(red: 0.45, green: 0.45, blue: 0.48)
        }
    }

    private var talkIcon: String {
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

    private var talkButton: some View {
        ZStack {
            Circle().fill(talkColor)
            Image(systemName: talkIcon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: talkSize, height: talkSize)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in model.pressBegan() }
                .onEnded { _ in model.pressEnded() }
        )
        .onTapGesture(count: 2) {
            model.toggle()
        }
        .help("Talk: hold to talk to Firstmate, or click to start and click again to send (or hold Right Option)")
        .accessibilityLabel("Talk to Firstmate")
        .overlay(alignment: .topTrailing) {
            if !model.keysTrusted {
                keysOffBadge.offset(x: 4, y: -4)
            }
        }
    }

    /// Show: hold it and speak, and the picture taken as it went down goes with
    /// the words; tap it and the picture goes alone. Taps stack, and the count
    /// shows on it; without Screen Recording it shows "!" and asks macOS again.
    private var showButton: some View {
        ZStack {
            Circle().fill(Self.wash)
            Circle().strokeBorder(Self.line)
            Image(systemName: "eye")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Self.ink)
        }
        .frame(width: showSize, height: showSize)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in model.showPressBegan() }
                .onEnded { _ in model.showPressEnded() }
        )
        .help(model.screenTrusted
              ? "Show: tap to send Firstmate the screen under the pointer, or hold and speak to send it with your words (or tap Right Shift)"
              : "Show is off: macOS has not allowed this build Screen Recording. Click to allow it.")
        .accessibilityLabel("Show Firstmate the screen")
        .overlay(alignment: .topTrailing) {
            if !model.screenTrusted {
                badge(Text("!"), fill: Self.orange)
                    .offset(x: 4, y: -4)
                    .allowsHitTesting(false)
            } else if model.shotCount > 0 {
                badge(Text("\(model.shotCount)"), fill: Self.blue)
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

    /// Shown while macOS has not granted this build Accessibility, so the
    /// hotkeys and dictation paste are off; clicking it asks again.
    private var keysOffBadge: some View {
        Button(action: model.fixKeys) {
            Image(systemName: "exclamationmark")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Self.orange))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Hotkeys are off: macOS has not allowed this build Accessibility. Click to allow it.")
        .accessibilityLabel("Hotkeys off - allow Accessibility")
    }

    // MARK: the reply bubble

    private var acting: Bool { model.offer?.isActing == true }

    /// Firstmate's newest reply, written for the eye, and any offer under it.
    /// Clicking the words opens the whole reply; the bubble never acts itself.
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if model.muted || model.speaking {
                    smallButton(model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                help: model.muted ? "Voice muted - click to unmute" : "Mute the voice",
                                tint: model.muted ? Self.orange : Self.soft,
                                action: model.toggleMute)
                }
                Text(model.caption.map { "Firstmate, \(Self.timeLabel($0.time))" } ?? "Firstmate")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Self.soft)
                Spacer(minLength: 8)
                if model.speaking || acting {
                    stopButton
                }
                if model.caption != nil {
                    smallButton(model.captionExpanded ? "chevron.up" : "chevron.down",
                                help: model.captionExpanded ? "Show less" : "Show all of the reply",
                                action: model.toggleCaptionExpanded)
                }
                smallButton("xmark", help: "Dismiss", action: model.dismissCaption)
            }
            if let reply = model.caption {
                replyText(reply)
                if !model.muted && !model.speaking {
                    Button(action: model.hearAgain) {
                        Label("Hear again", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Self.soft)
                    }
                    .buttonStyle(.plain)
                    .help("Speak this reply again")
                }
            }
            if let offer = model.shownOffer {
                offerBox(offer)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(width: model.captionExpanded ? 340 : 260, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Self.paper))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Self.line))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Firstmate's reply")
    }

    private func replyText(_ reply: Reply) -> some View {
        Group {
            if model.captionExpanded {
                ScrollView {
                    Text(Self.markdown(reply.full))
                        .font(.system(size: 12))
                        .foregroundStyle(Self.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(reply.eye)
                    .font(.system(size: 12))
                    .foregroundStyle(Self.ink)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: model.toggleCaptionExpanded)
                    .help("Click to read the whole reply")
            }
        }
    }

    /// The whole reply with its emphasis, code and links shown, line breaks kept.
    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func offerBox(_ offer: Offer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(offerLabel(offer))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Self.soft)
            Text(offer.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Self.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if offer.state == .open {
                HStack(spacing: 8) {
                    Button(action: model.doIt) {
                        Text("Do it")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Self.blue))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Ask Firstmate to take this step")
                    Button(action: model.notNow) {
                        Text("Not now")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Self.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().strokeBorder(Self.line))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Leave it")
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Self.wash))
    }

    private func offerLabel(_ offer: Offer) -> String {
        switch offer.state {
        case .accepted: return "Asked Firstmate to do this"
        case .working: return "Firstmate is doing this"
        case .stopping: return "Asked Firstmate to stop"
        default: return "Firstmate can do this for you"
        }
    }

    private var stopButton: some View {
        Button(action: model.stopAll) {
            HStack(spacing: 3) {
                Image(systemName: "stop.fill").font(.system(size: 7, weight: .bold))
                Text("Stop").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Self.stopRed))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(acting ? "Stop: ask Firstmate to stop, and stop the voice" : "Stop the voice")
        .accessibilityLabel("Stop")
    }

    private func smallButton(_ symbol: String, help: String, tint: Color? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(tint ?? Self.soft)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
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
}
