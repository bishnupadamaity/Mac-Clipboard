// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipStack",
    platforms: [.macOS(.v13)],
    targets: [
        // Capture, storage and retention live in a library so they can be tested;
        // the executable is the AppKit/SwiftUI shell around them.
        .target(name: "ClipStackCore", path: "Sources/ClipStackCore"),
        .executableTarget(name: "ClipStack", dependencies: ["ClipStackCore"], path: "Sources/ClipStack"),
        .testTarget(name: "ClipStackCoreTests", dependencies: ["ClipStackCore"], path: "Tests/ClipStackCoreTests"),
    ]
)
