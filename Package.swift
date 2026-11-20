// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MonitorControls",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MonitorControls", targets: ["MonitorControls"])],
    targets: [
        .target(name: "AudioRouting"),
        .target(name: "DisplayBridge", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreGraphics")]),
        .target(name: "DisplayHardware", dependencies: ["DisplayBridge"]),
        .target(name: "DeskPolicy"),
        .executableTarget(name: "MonitorControls", dependencies: ["AudioRouting", "DisplayHardware", "DeskPolicy"]),
        .testTarget(name: "AudioRoutingTests", dependencies: ["AudioRouting"]),
        .testTarget(name: "DisplayHardwareTests", dependencies: ["DisplayHardware"]),
        .testTarget(name: "DeskPolicyTests", dependencies: ["DeskPolicy"]),
        .testTarget(name: "DisplayAcceptance", dependencies: ["DisplayHardware"])
    ],
    swiftLanguageModes: [.v6]
)
