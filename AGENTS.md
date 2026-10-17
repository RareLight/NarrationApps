# NarrationApps development

Use docs/README.md, docs/ARCHITECTURE.md and docs/IMPLEMENTATION_STATUS.md for current state;
docs/IMPLEMENTATION_PLAN.md records remaining authorized work. This root repository owns
NarrationApps.xcworkspace, shared documentation/project scripts and swift-packages/.
Libro/ and VoiceRelay/ are independent, ignored Git repositories; inspect their AGENTS.md
before app-specific changes. The SwiftNarration manifest is swift-packages/Package.swift;
AppPresentation is its independent zero-dependency sibling package under that directory.
Keep maintained package sources/tests, patches, notices and preparation tools there.

Use native Swift and Apple APIs; maintain no Python runtime or product CLI. Keep MLX
helper-only, one speech worker per app, with Libro interactive priority and VoiceRelay
background priority through the shared lease. Never normalize, level, limit or apply gain
to audio. Preserve private data, model assets, user settings and completed recordings.
Keep pinned dependencies reproducible; never copy build caches between checkouts.

Run bash scripts/check.sh for workspace/layout, shared and app fixtures. Run both Debug
and Release workspace builds for layout/dependency changes. Use synthetic isolated
fixtures; GUI, listening, protected-file, live server and signing-account validation
remain operator-owned. Preserve unrelated pending changes and the apps' independent
histories. Update current docs when moving maintained files or changing setup.

CONTRIBUTING.md and docs/DEVELOPMENT.md own setup, tier selection and evidence.
Formatting is deliberately allowlisted by .devin/format-files.txt; never format
dependencies, patches, notices, generated output or golden fixtures recursively.
