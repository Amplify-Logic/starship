import XCTest
@testable import DeskFloater

final class HomeLocationTests: XCTestCase {
    private let bundle = "/home/me/starship/desk-floater/.build/DeskFloater.app"
    private let roots: Set<String> = ["/home/me/starship", "/home/me/other"]

    private func resolve(
        _ environment: [String: String],
        bundle: String? = nil,
        cwd: String = "/"
    ) -> (root: String, home: String)? {
        HomeLocation.resolve(
            environment: environment,
            bundlePath: bundle ?? self.bundle,
            currentDirectory: cwd,
            isCodeRoot: { self.roots.contains($0) }
        )
    }

    func testLauncherEnvironmentWins() {
        let location = resolve(["FM_DESK_FLOATER_ROOT": "/home/me/other", "FM_HOME": "/home/me/home"])
        XCTAssertEqual(location?.root, "/home/me/other")
        XCTAssertEqual(location?.home, "/home/me/home")
    }

    func testReopenWithoutEnvironmentFindsRootFromBundle() {
        let location = resolve([:])
        XCTAssertEqual(location?.root, "/home/me/starship")
        XCTAssertEqual(location?.home, "/home/me/starship", "the home defaults to the code root")
    }

    func testEmptyEnvironmentValuesCountAsUnset() {
        let location = resolve(["FM_DESK_FLOATER_ROOT": "", "FM_HOME": ""])
        XCTAssertEqual(location?.root, "/home/me/starship")
        XCTAssertEqual(location?.home, "/home/me/starship")
    }

    func testNeverFallsBackToSlash() {
        XCTAssertNil(resolve([:], bundle: "/Applications/DeskFloater.app"))
        XCTAssertNil(resolve([:], bundle: "/tmp/elsewhere/desk-floater/.build/DeskFloater.app"),
                     "a bundle outside a Firstmate code root is not trusted")
    }

    func testWorkingDirectoryCountsOnlyWhenItIsACodeRoot() {
        let location = resolve([:], bundle: "/tmp/x/DeskFloater", cwd: "/home/me/other")
        XCTAssertEqual(location?.root, "/home/me/other")
        XCTAssertEqual(location?.home, "/home/me/other")
        XCTAssertNil(resolve([:], bundle: "/tmp/x/DeskFloater", cwd: "/home/me/nowhere"),
                     "a working directory that is not a code root is not trusted")
    }

    // MARK: - TMPDIR

    /// A scratch folder for one test, removed afterwards with TMPDIR restored.
    private func scratch() throws -> URL {
        let saved = ProcessInfo.processInfo.environment["TMPDIR"]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("desk-floater-tmpdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            if let saved {
                setenv("TMPDIR", saved, 1)
            } else {
                unsetenv("TMPDIR")
            }
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func folder(_ name: String, in dir: URL) throws -> String {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func testTemporaryDirectoryKeepsAUsableFolder() throws {
        let good = try folder("good", in: scratch())
        XCTAssertEqual(HomeLocation.temporaryDirectory(current: good, systemDefault: "/elsewhere"), good)
    }

    func testDeletedTemporaryDirectoryFallsBackToTheSystemDefault() throws {
        let dir = try scratch()
        let system = try folder("system", in: dir)
        let gone = dir.appendingPathComponent("deleted").path
        XCTAssertEqual(HomeLocation.temporaryDirectory(current: gone, systemDefault: system), system)
    }

    func testAFileIsNotATemporaryDirectory() throws {
        let dir = try scratch()
        let system = try folder("system", in: dir)
        let file = dir.appendingPathComponent("file").path
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data()))
        XCTAssertEqual(HomeLocation.temporaryDirectory(current: file, systemDefault: system), system)
    }

    func testATemporaryDirectoryItCannotWriteToFallsBack() throws {
        let dir = try scratch()
        let system = try folder("system", in: dir)
        let locked = try folder("locked", in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked) }
        try XCTSkipIf(access(locked, W_OK) == 0, "this user can write to any folder")
        XCTAssertEqual(HomeLocation.temporaryDirectory(current: locked, systemDefault: system), system)
    }

    func testUnsetOrEmptyTemporaryDirectoryFallsBack() throws {
        let system = try folder("system", in: scratch())
        XCTAssertEqual(HomeLocation.temporaryDirectory(current: nil, systemDefault: system), system)
        XCTAssertEqual(HomeLocation.temporaryDirectory(current: "", systemDefault: system), system)
    }

    func testBrokenSystemTemporaryDirectoryFallsBackToTmp() throws {
        let gone = try scratch().appendingPathComponent("deleted").path
        XCTAssertEqual(HomeLocation.temporaryDirectory(current: gone, systemDefault: gone), "/tmp")
        XCTAssertEqual(HomeLocation.temporaryDirectory(current: gone, systemDefault: nil), "/tmp")
    }

    func testNoUsableTemporaryDirectoryLeavesTheChoiceToTheCaller() {
        XCTAssertNil(HomeLocation.temporaryDirectory(current: "/gone", systemDefault: "/gone", isUsable: { _ in false }))
    }

    func testRepairLeavesAUsableTMPDIRAlone() throws {
        let good = try folder("good", in: scratch())
        setenv("TMPDIR", good, 1)
        XCTAssertNil(HomeLocation.repairTemporaryDirectory())
        XCTAssertEqual(ProcessInfo.processInfo.environment["TMPDIR"], good)
    }

    /// The reported failure, end to end: a floater started with TMPDIR naming
    /// a deleted folder runs the real transcription helper, as it does for
    /// every recording. Before the repair the helper cannot make its temporary
    /// file and fails, which the floater shows as "Saved - retrying"; after it
    /// the transcript comes back.
    func testRepairLetsTheTranscriptionHelperRunWithADeletedTMPDIR() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let stt = root.appendingPathComponent("bin/fm-deepgram-stt.sh").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: stt), "no transcription helper at \(stt)")

        let dir = try scratch()
        let home = try folder("home", in: dir)
        let audio = dir.appendingPathComponent("clip.wav").path
        XCTAssertTrue(FileManager.default.createFile(atPath: audio, contents: Data("RIFF".utf8)))
        // A stand-in curl writes a Deepgram answer to the file named after -o
        // and prints HTTP 200, so nothing leaves this machine.
        let curl = dir.appendingPathComponent("curl").path
        let body = #"{"results":{"channels":[{"alternatives":[{"transcript":"hello from the floater"}]}]}}"#
        let script = """
            #!/usr/bin/env bash
            out=; prev=
            for a in "$@"; do [ "$prev" != -o ] || out=$a; prev=$a; done
            printf '%s' '\(body)' > "$out"
            printf 200
            """
        XCTAssertTrue(FileManager.default.createFile(atPath: curl, contents: Data(script.utf8),
                                                     attributes: [.posixPermissions: 0o755]))

        func transcribe() throws -> (status: Int32, out: String) {
            // As the floater runs a helper: its own environment plus FM_HOME.
            var environment = ProcessInfo.processInfo.environment
            environment["FM_HOME"] = home
            environment["FM_DEEPGRAM_ENV_FILE"] = "/dev/null"
            environment["DEEPGRAM_API_KEY"] = "test-key-not-real"
            environment["FM_DEEPGRAM_CURL"] = curl
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: stt)
            proc.arguments = [audio]
            proc.environment = environment
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return (proc.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        let gone = dir.appendingPathComponent("deleted-by-an-installer").path
        setenv("TMPDIR", gone, 1)
        let before = try transcribe()
        XCTAssertNotEqual(before.status, 0, "the helper must fail with a deleted TMPDIR, or this test proves nothing")

        let repaired = try XCTUnwrap(HomeLocation.repairTemporaryDirectory())
        XCTAssertNotEqual(repaired, gone)
        XCTAssertTrue(HomeLocation.isUsableTemporaryDirectory(repaired))
        let after = try transcribe()
        XCTAssertEqual(after.status, 0)
        XCTAssertEqual(after.out.trimmingCharacters(in: .whitespacesAndNewlines), "hello from the floater")
    }
}
