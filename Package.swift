// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SleepMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SleepMac", targets: ["SleepMac"])
    ],
    targets: [
        // Pure logic (commands, shell runner, assertion scanner). No AppKit, fully unit-tested.
        .target(name: "SleepMacCore"),
        // Menu bar app: status item, menu, command editor window.
        .executableTarget(name: "SleepMac", dependencies: ["SleepMacCore"]),
        .testTarget(name: "SleepMacCoreTests", dependencies: ["SleepMacCore"])
    ]
)
