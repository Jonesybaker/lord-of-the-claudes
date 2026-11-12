// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LordOfTheClaudes",
    platforms: [.macOS(.v14)],
    targets: [
        // What the app and `lotc` both speak: the socket protocol and order-keeping JSON.
        .target(name: "LotcKit", path: "Sources/LotcKit"),
        .executableTarget(name: "LordOfTheClaudes", dependencies: ["LotcKit"], path: "Sources/LordOfTheClaudes"),
        .executableTarget(name: "lotc", dependencies: ["LotcKit"], path: "Sources/lotc"),
    ]
)
