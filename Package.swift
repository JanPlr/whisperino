// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Whisperino",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Whisperino", targets: ["Whisperino"]),
    ],
    dependencies: [
        // Direct MediaRemote access is blocked for ordinary applications on
        // current macOS releases. This adapter uses an entitled system helper
        // to read and control the real Now Playing session reliably.
        .package(
            url: "https://github.com/ejbills/mediaremote-adapter.git",
            revision: "b4ae765bbfa111f1e8fad240a8ea74f01e91d325"
        ),
    ],
    targets: [
        // Official transcribe.cpp 0.2.1 xcframework (Metal + CPU on macOS arm64).
        .binaryTarget(
            name: "CTranscribe",
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.2.1/TranscribeCpp.xcframework.zip",
            checksum: "d24e6c0aaff1e628a626f792f74bb7155287a49a5c5bb1179deb73b35f0410f5"
        ),
        .target(
            name: "TranscribeCpp",
            dependencies: ["CTranscribe"],
            path: "Vendor/TranscribeCpp",
            exclude: ["LICENSE"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .executableTarget(
            name: "Whisperino",
            dependencies: [
                "TranscribeCpp",
                .product(name: "MediaRemoteAdapter", package: "mediaremote-adapter"),
            ],
            path: "Sources/Whisperino"
        ),
        .testTarget(
            name: "WhisperinoTests",
            dependencies: ["Whisperino"],
            path: "Tests/WhisperinoTests"
        ),
    ]
)
