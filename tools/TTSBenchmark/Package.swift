// swift-tools-version: 6.2
import Foundation
import PackageDescription

// The isolated fixture tier never resolves MLX or accesses model assets.
let coreOnly = ProcessInfo.processInfo.environment["TTS_BENCH_CORE_ONLY"] == "1"
let prepared = "../../swift-packages/.build/dependencies/"
var products: [Product] = [.executable(name: "tts-benchmark", targets: ["TTSBenchmark"])]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "BenchmarkCore", resources: [.process("Web")]),
    .executableTarget(name: "TTSBenchmark", dependencies: ["BenchmarkCore"]),
    .executableTarget(name: "BenchmarkFixtureWorker", dependencies: ["BenchmarkCore"]),
    .testTarget(name: "BenchmarkCoreTests", dependencies: ["BenchmarkCore"]),
]
if !coreOnly {
    dependencies = [
        .package(path: prepared + "mlx-audio-swift"),
        .package(path: prepared + "mlx-swift"),
        .package(path: prepared + "mlx-swift-lm"),
        .package(path: prepared + "swift-huggingface"),
        .package(path: "../../swift-packages"),
    ]
    products += [.executable(name: "tts-benchmark-worker", targets: ["TTSBenchmarkWorker"]),
                 .executable(name: "tts-narration-quality", targets: ["TTSNarrationQuality"]),
                 .executable(name: "tts-benchmark-reference", targets: ["TTSBenchmarkReference"])]
    targets += [
        .executableTarget(name: "TTSNarrationQuality", dependencies: ["BenchmarkCore",
            .product(name: "Pronunciation", package: "swift-packages"),
            .product(name: "NarrationCore", package: "swift-packages"),
            .product(name: "NativeSpeech", package: "swift-packages"),
            .product(name: "ProcessingPipeline", package: "swift-packages"),
            .product(name: "AudioOutput", package: "swift-packages")]),
        .executableTarget(name: "TTSBenchmarkWorker", dependencies: ["BenchmarkCore",
            .product(name: "NarrationCore", package: "swift-packages"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
            .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface")]),
        .executableTarget(name: "TTSBenchmarkReference", dependencies: ["BenchmarkCore",
            .product(name: "NarrationCore", package: "swift-packages"),
            .product(name: "NativeSpeech", package: "swift-packages"),
            .product(name: "ProcessingPipeline", package: "swift-packages"),
            .product(name: "AudioOutput", package: "swift-packages")]),
    ]
}
let package = Package(name: "TTSBenchmark", platforms: [.macOS("27.0")],
    products: products, dependencies: dependencies, targets: targets)
