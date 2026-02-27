// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Whisperino",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Whisperino",
            path: "Sources/Whisperino"
        ),
    ]
)
