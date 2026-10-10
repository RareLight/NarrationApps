// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceRelay",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "VoiceRelayCore", targets: ["VoiceRelayCore"]),
        .executable(name: "voicerelay", targets: ["VoiceRelayCLI"]),
        .executable(name: "VoiceRelayApp", targets: ["VoiceRelayApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/wolfyy970/swift-readability.git", exact: "0.3.3"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.6"),
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5")
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "VoiceRelayRuntimeResources", path: "runtime", exclude: ["kokoro/tests", "kokoro/__pycache__"],
            sources: ["RuntimeResources.swift"], resources: [
                .copy("kokoro/provider.py"), .copy("kokoro/runtime_setup.py"),
                .copy("kokoro/selection.json"), .copy("kokoro/requirements.lock"),
                .copy("kokoro/python-downloads.json")
            ]),
        .target(name: "VoiceRelayCore", dependencies: [
            "CSQLite", "VoiceRelayRuntimeResources", .product(name: "SwiftReadability", package: "swift-readability"),
            .product(name: "SwiftSoup", package: "SwiftSoup"),
            .product(name: "TOMLDecoder", package: "TOMLDecoder")
        ], resources: [.copy("Resources/article.html")]),
        .executableTarget(name: "VoiceRelayCLI", dependencies: ["VoiceRelayCore"]),
        .executableTarget(name: "VoiceRelayApp", dependencies: ["VoiceRelayCore"]),
        .testTarget(name: "VoiceRelayCoreTests", dependencies: ["VoiceRelayCore", "CSQLite"]),
        .testTarget(name: "VoiceRelayAppTests", dependencies: ["VoiceRelayApp", "VoiceRelayCore"])
    ]
)
