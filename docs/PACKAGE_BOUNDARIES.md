# Package boundaries and consumption

## Current packages

SwiftNarration is the root manifest name. Its eight public library products are
NarrationCore, DocumentProcessing, NativeSpeech, AudioOutput, ProcessingPipeline,
Pronunciation, PronunciationUI and NarrationUI. NativeSpeechEngine is helper-only;
GUI targets must not link MLX. Products/import module names remain distinct from
the SwiftPM package's source identity.

AppPresentation is a separate Swift package under `AppPresentation/`, with no
external dependencies and no narration/document/audio/model dependency. It provides
semantic typography, 80–200% text sizing/commands, adaptive Settings navigation,
section help, notices and Appearance controls. Apps retain preference persistence,
pane inventory, layout and scene lifetime. It can be consumed by non-TTS apps alone.

ProcessingPipeline remains speech-specific: it owns model setup, prepared speech,
speech IPC, PCM validation and inference admission. It is not a general-purpose
worker scheduler. Extract generic process supervision only when another concrete
consumer demonstrates that need; no speculative extra package exists today.

## Local Xcode and SwiftPM setup

Keep the shared checkout at `swift-packages`. Each app depends on this repository;
neither app depends on the other app's repository. Add the shared root and the
`AppPresentation/` directory as two local packages in Xcode and link only the needed
products to each target. Helpers link NativeSpeechEngine; GUIs use contracts/UI.

```swift
.package(path: "../swift-packages")
.package(path: "../swift-packages/AppPresentation")
// Examples of target dependencies:
.product(name: "NarrationCore", package: "swift-packages")
.product(name: "AppPresentation", package: "apppresentation")
```

SwiftNarration is the displayed manifest name; local identity remains
`swift-packages` because it follows the checkout path. AppPresentation's identity
is `apppresentation`. Existing module imports are unchanged. Prepare pinned native
sources with `bash scripts/prepare-dependencies.sh` from this repository before
opening an app project. AppPresentation alone requires no narration preparation.
Each app builds its own shared code and bundles its own worker/resources.

The persisted NativeNarration lock/version identifiers that remain in source are
intentional compatibility contracts. Do not rename them cosmetically and split
cross-app admission or invalidate checkpoints.

## Management and independent releases

Keep common implementation/tests/docs here; keep app workflows/preferences in their
own repositories. Apps can adopt a shared change by rebuilding local packages;
they do not copy source or maintain a sibling app checkout. Current integration
uses local paths, with manifests, dependency locks and patches under version control.
Build caches, models, credentials and generated media remain private/ignored.

Remote Git release needs a package-root repository/export for each independently
consumable package. AppPresentation can be exported/versioned independently from
this canonical source; a Git subdirectory URL is not the local-path installation
mechanism. A future registry strategy can publish separately scoped packages.
Before remote SwiftNarration publication, make pinned patched dependencies available
through a release-ready source strategy rather than expecting ignored `.build`
checkouts to exist. Coordinate product/API, asset/frontend and record-version
changes; preserve installed settings and finished recordings.

The original [naming assessment](history/PACKAGE_NAMING_2026-10-14.md) records why
SwiftNarration was selected over tts-swift. It is dated discovery evidence, not
name ownership or a current registry availability check. Publication remains
separate work; no remote installation path is implied by local Xcode success.

See [architecture](ARCHITECTURE.md), [Settings ownership](SETTINGS_ALIGNMENT.md),
[pronunciation](PRONUNCIATION.md), [samples](VOICE_SAMPLES.md) and
[dependency provenance](DEPENDENCIES.md) for current contracts.
