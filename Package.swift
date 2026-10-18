// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "voicetype",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "voicetype", targets: ["Voicetype"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0"),
        // 通用语音推理引擎（ggml），用来跑 Qwen3-ASR 的 GGUF 权重。
        // 见 Vendor/transcribe-cpp/VENDOR.md
        .package(path: "Vendor/transcribe-cpp")
    ],
    targets: [
        .executableTarget(
            name: "Voicetype",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "TranscribeCpp", package: "transcribe-cpp")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VoicetypeTests",
            dependencies: ["Voicetype"]
        )
    ]
)
