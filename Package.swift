// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "UniPack", platforms: [.macOS("26.0")], products: [
    .executable(name: "UniPack", targets: ["UniPack"]),
    .executable(name: "unipack-cli", targets: ["UniPackCLI"])
], targets: [
    .target(name: "UniPackCore", resources: [.copy("Resources")]),
    .executableTarget(name: "UniPack", dependencies: ["UniPackCore"]),
    .executableTarget(name: "UniPackCLI", dependencies: ["UniPackCore"])
], swiftLanguageModes: [.v5])
