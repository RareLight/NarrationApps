// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LibroCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "LibroCore", targets: ["LibroCore"])
    ],
    dependencies: [.package(path: "../../../swift-packages")],
    targets: [
        .target(name: "LibroCore", dependencies: [.product(name: "Pronunciation", package: "swift-packages"), .product(name: "NarrationCore", package: "swift-packages"), .product(name: "DocumentProcessing", package: "swift-packages"), .product(name: "NativeSpeech", package: "swift-packages"), .product(name: "AudioOutput", package: "swift-packages"), .product(name: "ProcessingPipeline", package: "swift-packages")]),
        .testTarget(name: "LibroCoreTests", dependencies: ["LibroCore"])
    ],
    swiftLanguageModes: [.v6]
)
