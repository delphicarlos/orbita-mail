// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrbitaMail",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OrbitaMail", targets: ["OrbitaMail"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "CMailTransport", linkerSettings: [.linkedLibrary("curl")]),
        .target(name: "OrbitaCore", dependencies: ["CSQLite", "CMailTransport"]),
        .executableTarget(name: "OrbitaMail", dependencies: ["OrbitaCore"]),
        .testTarget(name: "OrbitaCoreTests", dependencies: ["OrbitaCore"])
    ],
    swiftLanguageModes: [.v5]
)
