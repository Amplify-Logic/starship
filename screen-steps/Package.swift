// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenSteps",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ScreenSteps", targets: ["ScreenSteps"])
    ],
    targets: [
        .executableTarget(
            name: "ScreenSteps",
            path: "Sources"
        ),
        .testTarget(
            name: "ScreenStepsTests",
            dependencies: ["ScreenSteps"],
            path: "Tests/ScreenStepsTests"
        )
    ]
)
