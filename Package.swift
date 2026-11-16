// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "QwenReader",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "QwenReader", targets: ["QwenReader"]),
    ],
    dependencies: [
        // mlx-audio-swift has no tagged releases; pin the commit this app was tested against.
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "5c4c12b699234f55d1816dfdb36f7016086a49bb"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMinor(from: "0.32.3")),
    ],
    targets: [
        // Pure Swift logic with no MLX dependency, so it can be unit tested quickly:
        // text chunking, language detection, and downloading and installing the model.
        .target(name: "ReaderCore"),
        .executableTarget(
            name: "QwenReader",
            dependencies: [
                "ReaderCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
            ],
            // MLX types are not Sendable; Swift 5 mode keeps strict concurrency checks as warnings.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"]),
    ]
)
