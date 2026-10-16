# Package boundaries and consumption

## Current packages

SwiftNarration is the manifest name in `swift-packages/Package.swift`. Its eight public library products are
NarrationCore, DocumentProcessing, NativeSpeech, AudioOutput, ProcessingPipeline,
Pronunciation, PronunciationUI and NarrationUI. NativeSpeechEngine is helper-only;
GUI targets must not link MLX. Products/import module names remain distinct from
the SwiftPM package's source identity.

AppPresentation is a separate Swift package under `swift-packages/AppPresentation/`, with no
external dependencies and no narration/document/audio/model dependency. It provides
semantic typography, 80–200% text sizing/commands, adaptive Settings navigation,
section help, notices and Appearance controls. Apps retain preference persistence,
pane inventory, layout and scene lifetime. It can be consumed by non-TTS apps alone.

ProcessingPipeline remains speech-specific: it owns model setup, prepared speech,
speech IPC, PCM validation and inference admission. It is not a general-purpose
worker scheduler. Extract generic process supervision only when another concrete
consumer demonstrates that need; no speculative extra package exists today.

## Local Xcode and SwiftPM setup

Keep the shared package directory at `swift-packages` inside NarrationApps. Each app
depends on these package sources;
neither app depends on the other app's repository. Add `swift-packages/` and
`swift-packages/AppPresentation/` as two local packages in Xcode and link only the needed
products to each target. Helpers link NativeSpeechEngine; GUIs use contracts/UI.

```swift
.package(path: "../swift-packages")
.package(path: "../swift-packages/AppPresentation")
// Examples of target dependencies:
.product(name: "NarrationCore", package: "swift-packages")
.product(name: "AppPresentation", package: "apppresentation")
```

SwiftNarration is the displayed manifest name; local identity remains
`swift-packages` because it follows the package directory name. AppPresentation's identity
is `apppresentation`. Existing module imports are unchanged. Prepare pinned native
sources with `bash swift-packages/scripts/prepare-dependencies.sh` from the parent
NarrationApps root before
opening an app project. AppPresentation alone requires no narration preparation.
Each app builds its own shared code and bundles its own worker/resources.

The persisted NativeNarration lock/version identifiers that remain in source are
intentional compatibility contracts. Do not rename them cosmetically and split
cross-app admission or invalidate checkpoints.

## Develop both apps in one Xcode workspace

Open [NarrationApps.xcworkspace](../NarrationApps.xcworkspace) when working on
Libro and VoiceRelay together. The root repository owns the workspace and `swift-packages/`; `Libro/` and
`VoiceRelay/` are independent nested repositories ignored by the root Git history. Close
standalone Libro/VoiceRelay project windows and any separately opened shared
packages first: Xcode refuses to open a local package already owned by another
project/workspace, then reports its products as missing. Reinstalling Xcode or
changing app dependencies does not solve that ownership conflict. This is an
editor/workspace restriction, separate from running the installed apps together.

The workspace references both existing projects without copying files, merging
repositories or adding dependencies between the apps. Select **Libro** or
**VoiceRelay** to run/profile/archive that app. **Build Both Apps** is build-only;
it compiles both apps and helpers with a single resolved package graph. It is not
an archive/distribution scheme. Debug and Release use the same workspace graph.
Existing per-app Run configuration choices are preserved; choose Debug in
Edit Scheme when debugging, or pass `-configuration Debug` to xcodebuild.

From the NarrationApps root:

```sh
bash scripts/resolve-xcode-workspace.sh
xcodebuild -workspace NarrationApps.xcworkspace -scheme 'Build Both Apps' \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
# Repeat with -configuration Release for the release build.
```

Use your normal local signing configuration. Engineering validation can override
signing on the command line without changing team settings. The workspace's
tracked `xcshareddata/swiftpm/Package.resolved` starts with the shared package's
canonical remote pins plus VoiceRelay's TOMLDecoder pin; standalone project lockfiles
remain independent. Update the workspace lock deliberately with shared dependency
changes. Workspace build products/caches and per-user state remain ignored.

A single app can still use its standalone project without the other repository.
For simultaneous GUI work, open only the combined workspace. Additional editor
windows must belong to that same workspace, not reopen either `.xcodeproj`.
See [Apple's workspace guidance](https://developer.apple.com/documentation/xcode/managing-multiple-projects-and-their-dependencies).

## Management and independent releases

Keep common implementation/tests under `swift-packages/`, cross-app docs here and
project support under root `scripts/`; keep app workflows/preferences in their own
ignored nested repositories. Apps can adopt a shared change by rebuilding local packages;
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

The SwiftNarration naming decision is recorded in Git history. The name is not a
registry reservation; remote publication remains separate work.

See [architecture](ARCHITECTURE.md), [Settings ownership](SETTINGS_ALIGNMENT.md),
[pronunciation](PRONUNCIATION.md), [samples](VOICE_SAMPLES.md) and
[dependency provenance](DEPENDENCIES.md) for current contracts.
