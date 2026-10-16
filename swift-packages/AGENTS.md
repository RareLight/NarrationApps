# Shared native packages

Follow ../AGENTS.md and ../docs/README.md. SwiftNarration uses this directory's
Package.swift; AppPresentation/ is independent and must remain outside that manifest's
sources/tests. ProcessingPipeline remains narration-specific. Keep MLX out of GUI
consumers, speech single-worker, audio levels unchanged and pins/patches reproducible.
Run bash scripts/check.sh here for package fixtures. Cross-app orchestration and Xcode
workspace support belong to the parent repository's scripts/ and NarrationApps.xcworkspace.
