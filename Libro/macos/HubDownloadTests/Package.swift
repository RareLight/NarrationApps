// swift-tools-version: 6.2
import PackageDescription

// Controlled HTTP fixtures against the exact SDK used by the native worker.
// No models, MLX, Python environment or external HTTP requests are needed.
let package = Package(
    name: "LibroHubDownloadTests",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../.build/dependencies/swift-huggingface")],
    targets: [.testTarget(name: "HubDownloadTests", dependencies: [
        .product(name: "HuggingFace", package: "swift-huggingface")
    ])],
    swiftLanguageModes: [.v6]
)
