// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeskFloater",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DeskFloater", targets: ["DeskFloater"])
    ],
    targets: [
        .executableTarget(
            name: "DeskFloater",
            path: "Sources"
        ),
        .testTarget(
            name: "DeskFloaterTests",
            dependencies: ["DeskFloater"],
            path: "Tests/DeskFloaterTests"
        )
    ]
)
