// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LibroCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LibroCore", targets: ["LibroCore"]),
        .executable(name: "LibroNativeCheck", targets: ["LibroNativeCheck"])
    ],
    targets: [
        .target(name: "LibroCore"),
        .executableTarget(name: "LibroNativeCheck", dependencies: ["LibroCore"]),
        .testTarget(name: "LibroCoreTests", dependencies: ["LibroCore"])
    ],
    swiftLanguageModes: [.v6]
)
