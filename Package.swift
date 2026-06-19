// swift-tools-version:6.0
import PackageDescription

// Pure reading logic, split out so it can be built and verified on macOS
// without Xcode. The iOS app target (see project.yml) compiles the same
// Sources/FlowReadCore files alongside its SwiftUI shell.
//
// Note on testing: the Command Line Tools macOS SDK doesn't ship the XCTest /
// swift-testing swiftmodules, so a normal test target can't build here. Instead
// `CoreChecks` is a self-checking executable (run: `swift run CoreChecks`) that
// asserts the core's behavior and exits non-zero on failure. It can be promoted
// to a real XCTest target once full Xcode is available.
let package = Package(
    name: "FlowReadCore",
    products: [
        .library(name: "FlowReadCore", targets: ["FlowReadCore"]),
        .executable(name: "CoreChecks", targets: ["CoreChecks"]),
    ],
    targets: [
        .target(name: "FlowReadCore"),
        .executableTarget(name: "CoreChecks", dependencies: ["FlowReadCore"]),
    ]
)
