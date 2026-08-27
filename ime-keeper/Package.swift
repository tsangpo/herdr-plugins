// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ime-keeper",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ime-keeper", targets: ["ImeKeeper"])],
    targets: [
        .executableTarget(name: "ImeKeeper"),
        .testTarget(name: "ImeKeeperTests", dependencies: ["ImeKeeper"]),
    ],
    swiftLanguageModes: [.v5]
)
