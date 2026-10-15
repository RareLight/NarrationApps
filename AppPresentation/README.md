# AppPresentation

Independent Swift package for native macOS typography, app-wide text sizing,
Dynamic Type scaling, a 12-point floor, keyboard text-size commands, adaptive
Settings navigation, help, notices and Appearance controls.
Requires macOS 27.0, Swift 6 and SwiftUI/AppKit. It has **no external dependencies**
and no narration, document, model, audio or worker dependency.

Add this directory as a local package in Xcode and link the AppPresentation
product to the GUI target. Swift code continues to use `import AppPresentation`.
Each app owns preference persistence, layout, scene/window lifecycle and previews.

```swift
.package(path: "../swift-packages/AppPresentation")
// Target dependency:
.product(name: "AppPresentation", package: "apppresentation")
```

Run `swift test --package-path AppPresentation --disable-sandbox --no-parallel`
from the shared repository. UI-only consumers do not prepare or resolve the
SwiftNarration/MLX graph. Canonical source remains in this repository; a future
Git distribution requires its own package-root repository/release export, or
per-package registry publishing. A Git subdirectory URL is not a SwiftPM package.

Apps own pane inventory and persistence; shared Settings ownership is described in
[the package guide](../docs/SETTINGS_ALIGNMENT.md). Current integration/release
constraints are in [package boundaries](../docs/PACKAGE_BOUNDARIES.md).
