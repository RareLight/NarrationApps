# Libro native app

See [the app guide](../README.md), [documentation index](../docs/README.md),
[validation](../docs/VALIDATION.md),
and [shared dependency provenance](../../docs/DEPENDENCIES.md).
Commands in this guide run from `NarrationApps/Libro/`, not the monorepo root.
Complete [root setup](../../CONTRIBUTING.md#setup) first.

This project owns the app and a thin private worker entry point; shared capability
comes from the SwiftNarration package at `swift-packages`. Xcode links the separate
`swift-packages/AppPresentation` package for typography and keyboard sizing;
LibroCore needs only the narration package. See
[package boundaries and release management](../../docs/PACKAGE_BOUNDARIES.md).

First launch offers speech setup if the selected model is missing. Choose existing
prepared models, install the selected model, or defer setup. Without a selected
workspace, Install uses `~/Library/Application Support/Libro/SpeechRuntime`.
Downloads start only after Install; existing workspace preferences are preserved.
The main voice options include Play Sample/Stop Sample. Bundled recordings work
without model installation and use 1× speed, AAC-LC at 64 kbps/24 kHz, with natural
levels and no normalization. The current common phrase starts “Hello, I can narrate…” and does not include a voice name.
See [shared samples](../../docs/VOICE_SAMPLES.md).

During generation, document preparation reports file reading, PDF structure,
page text extraction, OCR rendering/recognition, image review/descriptions and
narration planning. EPUB preparation reports package structure and section counts
in reading order, including referenced note resources. Page-based progress covers the current preparation pass;
text extraction and image review have separate labels and counters. Steps without
measurable totals use a spinner. Updates are coalesced, and superseded updates
cannot replace a later document or speech phase.

For simultaneous Libro/VoiceRelay development, use the shared
[NarrationApps workspace](../../NarrationApps.xcworkspace), closing
standalone project and package windows first. An “already opened from another
project or workspace” error is a package ownership conflict; see
[workspace instructions](../../docs/PACKAGE_BOUNDARIES.md#develop-both-apps-in-one-xcode-workspace).
For that workspace, use `bash ../scripts/resolve-xcode-workspace.sh`
from the Libro root if a package refresh is needed.

For standalone Libro only, if Xcode reports missing AppPresentation or
`swift-packages_*` products after package changes, save your work and quit Xcode
completely, then run:

```sh
bash macos/scripts/resolve-xcode-packages.sh
```

Relaunch Xcode, reopen the project and build. This prepares pinned native sources and refreshes
Xcode's default package workspace without deleting caches or model assets.
`build.sh` uses separate repo-local DerivedData/SourcePackages; a successful build
there does not refresh the workspace used by the Xcode GUI.
Avoid deleting/resetting package checkouts while Xcode is open: it can retain
references to removed repositories. A refresh on disk does not confirm that the
running GUI has reloaded its package graph. If errors persist after relaunch,
inspect the first package-resolution error in the Report navigator, before the
summary “Missing package product” messages.

Current defaults and known pronunciation limitations are recorded in the
[shared status](../../docs/IMPLEMENTATION_STATUS.md). The sole manual
checklist is [operator validation](../../docs/OPERATOR_VALIDATION.md#libro);
older stage records are history. No generated build state or private assets should
be copied when relocating source.

## Standalone builds and Archives

From `Libro/`, after pinned setup:

```sh
bash macos/scripts/build.sh build
LIBRO_CONFIGURATION=Release bash macos/scripts/build.sh \
  -archivePath "$PWD/macos/.build/Archives/Libro.xcarchive" archive
```

The script prepares pinned source dependencies and uses `macos/.build/DerivedData`
and `macos/.build/SourcePackages`. It may need network source acquisition; it never
installs speech models. Normal signing follows the project/local Xcode setup.
For coordinated ad-hoc engineering builds/Archives and full bundle audits, prefer
root `bash scripts/check.sh --tier release --adhoc`. Do not replace an existing
operator candidate as a routine check.
