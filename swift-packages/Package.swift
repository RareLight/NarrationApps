// swift-tools-version: 6.2
import PackageDescription

let modules = ["NarrationCore", "DocumentProcessing", "NativeSpeech", "AudioOutput", "ProcessingPipeline", "Pronunciation", "PronunciationUI", "NarrationUI"]
let package = Package(
    name: "SwiftNarration",
    platforms: [.macOS("27.0")],
    products: modules.map { .library(name: $0, targets: [$0]) } + [
        .executable(name: "NarrationFixtureWorker", targets: ["NarrationFixtureWorker"]),
        .library(name: "NativeSpeechEngine", targets: ["NativeSpeechEngine"]),
        .executable(name: "NarrationSpeechWorker", targets: ["NarrationSpeechWorker"]),
        .executable(name: "NarrationNativeCheck", targets: ["NarrationNativeCheck"]),
        .executable(name: "VoiceSampleGenerator", targets: ["VoiceSampleGenerator"])
    ],
    dependencies: [
        .package(path: "AppPresentation"),
        .package(url: "https://github.com/wolfyy970/swift-readability.git", exact: "0.3.3"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.6"),
        .package(path: ".build/dependencies/ZIPFoundation"),
        .package(path: ".build/dependencies/mlx-audio-swift"),
        .package(path: ".build/dependencies/mlx-swift"),
        .package(path: ".build/dependencies/swift-huggingface"),
        // Consumers inherit the accepted engine API version; nested lockfiles alone do not pin it.
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.1.9")
    ],
    targets: [
        .target(name: "Pronunciation"),
        .target(name: "NarrationUI", dependencies: ["NarrationCore", "AudioOutput", .product(name: "AppPresentation", package: "apppresentation")]),
        .testTarget(name: "NarrationUITests", dependencies: ["NarrationUI", "NarrationCore"]),
        .target(name: "PronunciationUI", dependencies: ["Pronunciation", "NarrationCore", "NativeSpeech", "ProcessingPipeline", "AudioOutput"]),
        .testTarget(name: "PronunciationTests", dependencies: ["Pronunciation", "NarrationCore"]),
        .testTarget(name: "PronunciationUITests", dependencies: ["PronunciationUI", "Pronunciation", "NarrationCore", "AudioOutput"]),
        .target(name: "NarrationCore", dependencies: ["Pronunciation"]),
        .target(name: "DocumentProcessing", dependencies: ["NarrationCore", .product(name: "SwiftReadability", package: "swift-readability"), .product(name: "SwiftSoup", package: "SwiftSoup"), .product(name: "ZIPFoundation", package: "ZIPFoundation")]),
        .target(name: "NativeSpeech", dependencies: ["NarrationCore"], resources: [.copy("Resources/VoiceSamples")]),
        // Keep MLX out of GUI consumers; only private helpers link this target.
        .target(name: "NativeSpeechEngine", dependencies: [
            "NarrationCore", "NativeSpeech",
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
            .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Transformers", package: "swift-transformers")
        ]),
        .executableTarget(name: "NarrationSpeechWorker", dependencies: ["NativeSpeechEngine"]),
        .executableTarget(name: "NarrationNativeCheck", dependencies: ["NarrationCore", "DocumentProcessing", "NativeSpeech", "AudioOutput", "ProcessingPipeline"]),
        .executableTarget(name: "VoiceSampleGenerator", dependencies: ["Pronunciation", "NarrationCore", "NativeSpeech", "AudioOutput", "ProcessingPipeline"]),
        .testTarget(name: "VoiceSampleGeneratorTests", dependencies: ["VoiceSampleGenerator", "NarrationCore", "NativeSpeech", "AudioOutput"]),
        .target(name: "AudioOutput"),
        .target(name: "ProcessingPipeline", dependencies: ["Pronunciation", "NarrationCore", "DocumentProcessing", "NativeSpeech", "AudioOutput"]),
        .executableTarget(name: "NarrationFixtureWorker", dependencies: ["NarrationCore", "NativeSpeech", "ProcessingPipeline"]),
        .testTarget(name: "HubDownloadTests", dependencies: [.product(name: "HuggingFace", package: "swift-huggingface")]),
        .testTarget(name: "NativeSpeechTests", dependencies: ["NarrationCore", "NativeSpeech", "ProcessingPipeline", "AudioOutput", "DocumentProcessing"]),
        .testTarget(name: "DocumentProcessingTests", dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation"), "NarrationCore", "DocumentProcessing", "NativeSpeech", "ProcessingPipeline", "AudioOutput"]),
        .testTarget(name: "AudioOutputTests", dependencies: ["AudioOutput", "NarrationCore", "NativeSpeech", "DocumentProcessing", "ProcessingPipeline"]),
        .testTarget(name: "ProcessingPipelineTests", dependencies: ["NarrationCore", "DocumentProcessing", "NativeSpeech", "AudioOutput", "ProcessingPipeline"]),
        .testTarget(name: "NarrationCoreTests", dependencies: ["NarrationCore"])
    ],
    swiftLanguageModes: [.v6]
)
