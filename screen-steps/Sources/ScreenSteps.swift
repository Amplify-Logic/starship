import AppKit
import SwiftUI

/// The on-screen steps card bin/fm-screen-steps.sh shows over a page the
/// captain fills in. It only renders the card file that script writes and
/// runs that script for Done, Stuck and Close; the script header owns the
/// card's contract.
@main
struct ScreenStepsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: CardPanel?
    private var model: CardModel?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let env = ProcessInfo.processInfo.environment
        guard let root = env["FM_SCREEN_STEPS_ROOT"], !root.isEmpty,
              let dir = env["FM_SCREEN_STEPS_DIR"], !dir.isEmpty else {
            FileHandle.standardError.write(Data("ScreenSteps: start it with bin/fm-screen-steps.sh show\n".utf8))
            NSApp.terminate(nil)
            return
        }
        let model = CardModel(root: root, dir: dir)
        // Another card already serves this home: it picks the new steps up.
        guard model.claim() else {
            NSApp.terminate(nil)
            return
        }
        self.model = model
        model.poll()
        let panel = CardPanel(model: model)
        panel.orderFrontRegardless()
        self.panel = panel
        model.start()
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        model?.release()
    }
}

/// How a value shows in its chip: every character exactly as Copy copies it,
/// with a zero-width space after each one so a long value wraps at any
/// character instead of being hyphenated or truncated.
enum ValueText {
    static func wrappable(_ value: String) -> String {
        value.map(String.init).joined(separator: "\u{200B}")
    }
}

struct Card: Decodable, Equatable {
    struct Step: Decodable, Equatable {
        let text: String
        let values: [String]
    }

    let revision: String
    let title: String
    let note: String
    let steps: [Step]
}

@MainActor
final class CardModel: ObservableObject {
    @Published private(set) var card: Card?
    @Published private(set) var ticked: Set<Int> = []
    @Published private(set) var copied: String?
    @Published private(set) var status = ""
    @Published private(set) var sending = false

    private let root: String
    private let cardPath: String
    private let pidPath: String
    private var lastData: Data?
    private var timer: Timer?

    init(root: String, dir: String) {
        self.root = root
        cardPath = (dir as NSString).appendingPathComponent("card.json")
        pidPath = (dir as NSString).appendingPathComponent("card.pid")
    }

    /// Records this card as the home's one card, unless another live card
    /// already is.
    func claim() -> Bool {
        let own = ProcessInfo.processInfo.processIdentifier
        if let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid != own,
           NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return false
        }
        return (try? "\(own)\n".write(toFile: pidPath, atomically: true, encoding: .utf8)) != nil
    }

    func release() {
        let own = ProcessInfo.processInfo.processIdentifier
        if let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
           pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) == own {
            try? FileManager.default.removeItem(atPath: pidPath)
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// Picks up a replaced card, and closes once the card file is gone.
    func poll() {
        guard let data = FileManager.default.contents(atPath: cardPath) else {
            NSApp.terminate(nil)
            return
        }
        guard data != lastData else { return }
        lastData = data
        guard let next = try? JSONDecoder().decode(Card.self, from: data) else { return }
        if next.revision != card?.revision {
            ticked = []
            copied = nil
            status = ""
            sending = false
        }
        card = next
    }

    func toggle(_ index: Int) {
        if ticked.contains(index) {
            ticked.remove(index)
        } else {
            ticked.insert(index)
        }
    }

    func copy(_ value: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(value, forType: .string)
        copied = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.copied == value {
                self?.copied = nil
            }
        }
    }

    func done() {
        send(["reply", "done"]) { [weak self] sent in
            guard sent else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self?.close()
            }
        }
    }

    /// Names the first step not ticked, once the captain has ticked any.
    func stuck() {
        var args = ["reply", "stuck"]
        if let card, !ticked.isEmpty,
           let next = card.steps.indices.first(where: { !ticked.contains($0) }) {
            args += ["--step", String(next + 1)]
        }
        send(args) { _ in }
    }

    func close() {
        Self.run(root: root, args: ["hide"]) { _ in
            NSApp.terminate(nil)
        }
    }

    private func send(_ args: [String], then: @escaping (Bool) -> Void) {
        sending = true
        status = "Sending…"
        Self.run(root: root, args: args) { [weak self] out in
            self?.sending = false
            self?.status = Self.outcome(out)
            then(out != nil)
        }
    }

    /// The status for one bin/fm-desk-voice.sh send outcome line.
    nonisolated static func outcome(_ out: String?) -> String {
        guard let out else { return "Not sent - try again" }
        if out.hasPrefix("sent:") { return "Sent" }
        if out.hasPrefix("sent-unconfirmed:") { return "Sent, unconfirmed" }
        return "Saved for Firstmate"
    }

    /// Runs bin/fm-screen-steps.sh off the main thread; its stdout, or nil
    /// when it failed.
    private static func run(root: String, args: [String], then: @escaping @MainActor (String?) -> Void) {
        let bin = (root as NSString).appendingPathComponent("bin/fm-screen-steps.sh")
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = args
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = FileHandle.standardError
            var result: String?
            do {
                try proc.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    result = String(data: data, encoding: .utf8) ?? ""
                }
            } catch {
                result = nil
            }
            DispatchQueue.main.async {
                then(result)
            }
        }
    }
}

/// Takes a click on a card that is not the key window, so one click copies a
/// value or sends Done while the page keeps the keyboard.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class CardPanel: NSPanel {
    @MainActor
    init(model: CardModel) {
        let mover = WindowMover()
        let hosting = FirstClickHostingView(rootView: CardView(model: model, mover: mover))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        super.init(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        contentView = hosting
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        if let visible = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.maxX - hosting.frame.width - 20, y: visible.minY + 20))
        }
        mover.window = self
    }

    // The card has nothing to type into, so it never takes the keyboard from
    // the page.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Moves the card while its background is dragged, and resizes it to its
/// contents with the bottom-right corner kept where it is.
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

    func fit(_ size: CGSize) {
        guard let window, size.width > 0, size.height > 0 else { return }
        let frame = window.frame
        var rect = NSRect(x: frame.maxX - size.width, y: frame.minY, width: size.width, height: size.height)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            rect.origin.x = max(min(rect.origin.x, visible.maxX - rect.width), visible.minX)
            rect.origin.y = max(min(rect.origin.y, visible.maxY - rect.height), visible.minY)
        }
        if rect != frame {
            window.setFrame(rect, display: true)
            window.invalidateShadow()
        }
    }
}

struct CardView: View {
    @ObservedObject var model: CardModel
    let mover: WindowMover
    @State private var stepsHeight: CGFloat = 0

    private let width: CGFloat = 340

    private var maxStepsHeight: CGFloat {
        ((NSScreen.main?.visibleFrame.height ?? 800) * 0.6).rounded()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let card = model.card {
                header(card.title)
                if !card.note.isEmpty {
                    Text(card.note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ScrollView(.vertical) {
                    steps(card)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stepsHeight = $0 }
                }
                .frame(height: min(stepsHeight, maxStepsHeight))
                Divider()
                footer
            }
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                )
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { _ in mover.drag() }
                        .onEnded { _ in mover.end() }
                )
        )
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { mover.fit($0) }
    }

    private func header(_ title: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                model.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close the steps")
            .accessibilityLabel("Close")
        }
    }

    private func steps(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(card.steps.enumerated()), id: \.offset) { index, step in
                stepRow(index, step)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepRow(_ index: Int, _ step: Card.Step) -> some View {
        let done = model.ticked.contains(index)
        return HStack(alignment: .top, spacing: 10) {
            Button {
                model.toggle(index)
            } label: {
                ZStack {
                    Circle()
                        .fill(done ? Color.green : Color.accentColor.opacity(0.15))
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(done ? "Mark as not done" : "Mark as done")
            .accessibilityLabel("Step \(index + 1)")
            .accessibilityValue(done ? "done" : "not done")

            VStack(alignment: .leading, spacing: 6) {
                Text(Self.markdown(step.text))
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(step.values, id: \.self) { value in
                    valueRow(value)
                }
            }
        }
    }

    private func valueRow(_ value: String) -> some View {
        HStack(spacing: 6) {
            Text(ValueText.wrappable(value))
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(value)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
            Spacer(minLength: 4)
            Button(model.copied == value ? "Copied" : "Copy") {
                model.copy(value)
            }
            .controlSize(.small)
            .help("Copy \(value)")
            .accessibilityLabel("Copy \(value)")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Stuck") {
                model.stuck()
            }
            .help("Tell Firstmate you are stuck")
            .accessibilityLabel("Stuck")
            Button("Done") {
                model.done()
            }
            .buttonStyle(.borderedProminent)
            .help("Tell Firstmate you are done, and close the steps")
            .accessibilityLabel("Done")
        }
        .disabled(model.sending)
    }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
