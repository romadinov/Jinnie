// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JinnieCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "JinnieCore", targets: ["JinnieCore"]),
        .library(name: "JinnieAgent", targets: ["JinnieAgent"]),
        .executable(name: "jinnie", targets: ["jinnie"]),
    ],
    targets: [
        .target(name: "JinnieCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "JinnieAgent", dependencies: ["JinnieCore"]),
        .executableTarget(name: "jinnie", dependencies: ["JinnieCore", "JinnieAgent"]),
        .testTarget(name: "JinnieCoreTests", dependencies: ["JinnieCore", "JinnieAgent"]),
    ],
    swiftLanguageModes: [.v5]
)
