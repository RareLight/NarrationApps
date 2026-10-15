// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AppPresentation",
    platforms: [.macOS("27.0")],
    products: [.library(name: "AppPresentation", targets: ["AppPresentation"])],
    dependencies: [],
    targets: [
        .target(name: "AppPresentation"),
        .testTarget(name: "AppPresentationTests", dependencies: ["AppPresentation"])
    ],
    swiftLanguageModes: [.v6]
)
