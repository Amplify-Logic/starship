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
}
