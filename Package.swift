// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Shima",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Shima",
            path: "Sources/Shima",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
