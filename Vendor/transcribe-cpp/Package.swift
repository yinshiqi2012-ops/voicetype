// swift-tools-version: 5.9
import PackageDescription

// transcribe.cpp 的 Swift 绑定（本地 vendored 版本）。
//
// 原生库以预编译 `.xcframework` 形式提供（binaryTarget），模块名 `CTranscribe`
// 是裸 C 接口，`TranscribeCpp` 是它的 Swift 封装。
// 构建产物来自 scripts/ci/build_xcframework.sh（见 VENDOR.md）。
let package = Package(
    name: "transcribe-cpp",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TranscribeCpp", targets: ["TranscribeCpp"])
    ],
    targets: [
        .binaryTarget(name: "CTranscribe", path: "build-apple/TranscribeCpp.xcframework"),
        .target(
            name: "TranscribeCpp",
            dependencies: ["CTranscribe"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
    ]
)
