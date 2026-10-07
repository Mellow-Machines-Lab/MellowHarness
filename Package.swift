// swift-tools-version: 6.2
import PackageDescription

// MellowHarness: give anything a personality with Markdown and multiple choice
// (README.md). Foundation only, and nothing outside this folder: apps
// depend on it, never the other way round.
let package = Package(
    name: "mellowharness",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MellowHarness", targets: ["MellowHarness"]),
        .executable(name: "mellowharness-emit", targets: ["MellowHarnessEmit"]),
        .executable(name: "beacon", targets: ["BeaconDemo"]),
    ],
    targets: [
        // What apps link: events and the log, the harness, the brains,
        // `Choice`, steering and the socket in.
        .target(name: "MellowHarness"),
        // `mellowharness-emit`: sends one event to a harness's socket.
        .executableTarget(name: "MellowHarnessEmit", dependencies: ["MellowHarness"]),
        // The worked example, Beacon, its steering folder read
        // from the source tree, and `beacon`, which runs it.
        .target(name: "Beacon", dependencies: ["MellowHarness"], path: "Examples/Beacon", exclude: ["steering"]),
        .executableTarget(name: "BeaconDemo", dependencies: ["Beacon", "MellowHarness"], path: "Examples/BeaconDemo"),
        .testTarget(name: "MellowHarnessTests", dependencies: ["MellowHarness", "Beacon"]),
    ]
)
