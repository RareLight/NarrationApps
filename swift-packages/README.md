# Shared Swift packages

This directory contains SwiftNarration and the independent AppPresentation package.
The parent [NarrationApps repository](../README.md) owns the Xcode workspace,
shared documentation and project orchestration. The sibling Libro and VoiceRelay
folders are independent app repositories ignored by the parent Git repository.

SwiftPM identity remains `swift-packages`; product/module names and app dependency
paths are unchanged. Add this directory and `AppPresentation/` as local Xcode
packages. MLX remains linked only into private speech helpers.

From this directory:

```sh
bash scripts/prepare-dependencies.sh
bash scripts/check.sh
```

For both apps, open [NarrationApps.xcworkspace](../NarrationApps.xcworkspace) in the
parent and use [the root development guide](../README.md).
See [package boundaries](../docs/PACKAGE_BOUNDARIES.md),
[dependency provenance](../docs/DEPENDENCIES.md) and
[operator validation](../docs/OPERATOR_VALIDATION.md).
