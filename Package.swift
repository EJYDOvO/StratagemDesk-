// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "StratagemDesk", platforms: [.macOS(.v14)], products: [
    .library(name: "StratagemCore", targets: ["StratagemCore"]),
    .executable(name: "StratagemDesk", targets: ["StratagemDesk"])
], targets: [
    .target(name: "StratagemCore", resources: [.process("Resources"), .copy("Artwork")]),
    .executableTarget(name: "StratagemDesk", dependencies: ["StratagemCore"]),
    .testTarget(name: "StratagemCoreTests", dependencies: ["StratagemCore"])
])
