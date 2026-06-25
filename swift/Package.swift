// swift-tools-version:5.9
import PackageDescription

// CommandLineTools-only host (no full Xcode): Testing.framework is at
// cltFw and lib_TestingInterop.dylib is at cltUsr.  We embed both
// paths as rpaths in the test bundle so `swiftpm-testing-helper` can
// dlopen it.  The companion toolset-clt.json passes `-F cltFw` to
// swiftc so that the framework is discoverable at compile time AND as
// an argument to `swiftpm-testing-helper` so it can find the dylib at
// runtime.  Run tests via:
//   swift test --toolset toolset-clt.json --enable-swift-testing
let cltFw  = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltUsr = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "vz",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "VzCore", linkerSettings: [
            .linkedFramework("Virtualization"),
            .linkedFramework("AppKit"),
        ]),
        .executableTarget(name: "vz", dependencies: ["VzCore"]),
        .testTarget(
            name: "VzCoreTests",
            dependencies: ["VzCore"],
            linkerSettings: [
                .unsafeFlags([
                    "-F", cltFw,
                    "-framework", "Testing",
                    "-Xlinker", "-rpath", "-Xlinker", cltFw,
                    "-Xlinker", "-rpath", "-Xlinker", cltUsr,
                ]),
            ]
        ),
    ]
)
