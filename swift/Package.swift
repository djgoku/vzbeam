// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "vz",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "VzCore", linkerSettings: [
            .linkedFramework("Virtualization"),
            .linkedFramework("AppKit"),
        ]),
        .executableTarget(name: "vz", dependencies: ["VzCore"]),
        .executableTarget(name: "vzcheck", dependencies: ["VzCore"]),
    ]
)
