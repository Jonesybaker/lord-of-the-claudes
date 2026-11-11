// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LordOfTheClaudes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LordOfTheClaudes", path: "Sources/LordOfTheClaudes")
    ]
)
