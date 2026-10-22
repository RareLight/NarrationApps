# NarrationApps development

This monorepo owns `Libro/`, `VoiceRelay/`, `swift-packages/`, shared docs/scripts
and `NarrationApps.xcworkspace`. Start with docs/README.md, docs/ARCHITECTURE.md and
docs/IMPLEMENTATION_STATUS.md. docs/IMPLEMENTATION_PLAN.md separates remaining
acceptance from proposed work. Read the relevant app/package AGENTS.md before edits.
Historical implementation prompts and stage checklists are context, not new tasks.

SwiftNarration's manifest is swift-packages/Package.swift; AppPresentation is its
independent zero-dependency sibling package. Keep maintained sources/tests, patches,
notices and preparation tools with their owner. Both apps inherit root Git history;
commit coordinated changes once, without restoring obsolete app SHA pins.

Use native Swift/Apple APIs; maintain no Python runtime or product CLI. Keep MLX
helper-only, one speech worker per app, Libro interactive priority and VoiceRelay
background priority through the shared lease. Never normalize, level, limit or
apply gain to audio. Preserve original text/mappings, private data, model assets,
user settings, completed recordings and unrelated changes. Keep pinned dependencies
reproducible; never copy build caches between checkouts.

CONTRIBUTING.md and docs/DEVELOPMENT.md own setup, test tiers and evidence. Testing
is **autonomous** for relevant synthetic isolated checks (confirmed October 17,
2026). Run the narrowest adequate checks; bash scripts/check.sh is the full fixture
gate. Layout/dependency changes also need Debug and Release workspace builds.
GUI/Canvas, listening, protected-file, private-document, live-server and signing-
account acceptance remain operator-owned. Do not replace a bundle under active
operator testing or treat compilation as those acceptances.

Formatting is allowlisted by .devin/format-files.txt. Never recursively format
dependencies, patches, notices, generated output or golden fixtures. Update current
user/developer docs with behavior/setup changes using docs/DOCUMENTATION.md. Keep
historical evidence dated and third-party license/notice wording intact.
