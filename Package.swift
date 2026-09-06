// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ChatGPTBar",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic, no AppKit/WebKit. Everything here is covered by SelfTest.
        .target(name: "ChatGPTBarKit"),
        // The app itself: AppKit + WebKit wiring only.
        .executableTarget(name: "ChatGPTBar", dependencies: ["ChatGPTBarKit"]),
        // XCTest is unavailable on Command Line Tools only installs, so the
        // checks run as a normal executable: `swift run SelfTest`.
        .executableTarget(name: "SelfTest", dependencies: ["ChatGPTBarKit"]),
        // Emits the deterministic bridge source for browser fixture tests.
        .executableTarget(name: "BridgeDump", dependencies: ["ChatGPTBarKit"])
    ]
)
