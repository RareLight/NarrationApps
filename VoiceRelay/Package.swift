// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceRelay",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "VoiceRelayCore", targets: ["VoiceRelayCore"]),
        .executable(name: "VoiceRelayApp", targets: ["VoiceRelayApp"])
    ],
    dependencies: [
        .package(path: "../swift-packages"),
        .package(path: "../swift-packages/AppPresentation"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.6"),
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5")
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "VoiceRelayCore", dependencies: [
            "CSQLite", .product(name: "Pronunciation", package: "swift-packages"), .product(name: "NarrationCore", package: "swift-packages"), .product(name: "DocumentProcessing", package: "swift-packages"), .product(name: "NativeSpeech", package: "swift-packages"), .product(name: "ProcessingPipeline", package: "swift-packages"), .product(name: "AudioOutput", package: "swift-packages"),
            .product(name: "SwiftSoup", package: "SwiftSoup"),
            .product(name: "TOMLDecoder", package: "TOMLDecoder")
        ], resources: [.copy("Resources/article.html")]),
        .executableTarget(name: "VoiceRelayApp", dependencies: ["VoiceRelayCore", .product(name: "AudioOutput", package: "swift-packages"), .product(name: "PronunciationUI", package: "swift-packages"), .product(name: "NarrationUI", package: "swift-packages"), .product(name: "AppPresentation", package: "apppresentation")]),
        .testTarget(name: "VoiceRelayCoreTests", dependencies: ["VoiceRelayCore", "CSQLite"]),
        .testTarget(name: "VoiceRelayAppTests", dependencies: ["VoiceRelayApp", "VoiceRelayCore", .product(name: "AppPresentation", package: "apppresentation")])
    ]
)
