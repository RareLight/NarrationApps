# Libro for macOS — native M1 spike

The checked-in project targets **Xcode 27.0, Apple Silicon, macOS 15+ and Swift 6**. The window currently verifies the embedded native worker; the document queue/workflow is M2–M4 work. The Python CLI is independent.

## Build and open

```bash
bash macos/scripts/prepare-dependencies.sh
open macos/Libro/Libro.xcodeproj
```

Select the shared `Libro` scheme. `LibroSpeechWorker` is also shared and launches a Metal probe; `LibroCoreTests` builds the core fixtures separately. The app embeds the worker, signed Metal library, and worker Swift compatibility libraries. Ad-hoc development signing is the default; Developer ID, hardened-runtime acceptance and notarization are separate distribution work.

The reproducible terminal build keeps package clones, caches, modules and DerivedData under `macos/.build/` and forces arm64 for the package graph:

```bash
bash macos/scripts/build.sh -onlyUsePackageVersionsFromResolvedFile build
LIBRO_CONFIGURATION=Release bash macos/scripts/build.sh -onlyUsePackageVersionsFromResolvedFile -jobs 4 build
open macos/.build/DerivedData/Build/Products/Debug/Libro.app
```

If `xcrun metal --version` says the Metal Toolchain is missing, use Apple's `xcodebuild -downloadComponent MetalToolchain`. It was installed for this machine's first native build. Do not replace the selected Xcode or the CLI environment.

## Fast fixtures

```bash
bash macos/scripts/check.sh
```

These cover defaults, native asset containment/missing/partial assets, incremental PCM16 order and clipping, and preservation/cleanup after cancellation or invalid samples. They do not run MLX or establish speech/GUI acceptance. Xcode's test action may require a macOS privacy prompt for its test runner to access a checkout on Desktop/Documents. SwiftPM's fixtures can run independently; do not alter OS permissions silently.

## Opt-in real speech

The spike reuses compatible primary snapshots read-only at the existing `models/kokoro/mlx-community__Kokoro-82M-bf16` and `models/soprano/mlx-community__Soprano-1.1-80M-bf16` paths. It never rewrites the Python manifest. Native primary acquisition is still M5 work.

Explicitly prepare the pinned English G2P assets, then use the native acceptance harness. Supply absolute paths for the worker, selected Libro workspace and chosen sample output directory:

```bash
WORKER="$PWD/macos/.build/DerivedData/Build/Products/Debug/Libro.app/Contents/Helpers/LibroSpeechWorker"
"$WORKER" --prepare-g2p "$PWD"
swift build --package-path macos/LibroCore --scratch-path macos/.build/CoreTests --product LibroNativeCheck
macos/.build/CoreTests/debug/LibroNativeCheck "$WORKER" "$PWD" "$PWD/macos/.build/acceptance/offline" serial --offline
```

The offline harness uses `sandbox-exec` to block networking and native/CLI/global HF cache access in each fresh worker. Both explicit primary and prepared G2P directories must be complete. Workers spool bounded float32 audio under `models/.native/staging/`; the harness validates it and uses the shared atomic PCM16 WAV writer. This is an opt-in development check, not the finished scheduler/IPC protocol. It publishes one short sample per model and retains metadata/diagnostics for listening. Soprano is stochastic, so frame counts/audio bytes can differ between runs.

For relocation testing, copy the built app, the native harness, K/S primary directories and prepared native auxiliary directory to another workspace. Omit `.venv` and all HF caches. `LIBRO_CHECK_DENY_ROOT=/absolute/original/checkout` additionally denies source-checkout reads inside offline workers. This diagnostic does not grant sandboxed-app bookmark access; Finder/privacy/bookmark GUI acceptance remains open.

See `DEPENDENCIES.md` for exact graph/asset pins, the narrow prepared-directory Misaki patch, update procedure and notices. Reverting native files and the native ignore rules removes this slice without changing the CLI installation. Do not include the GUI in today's portable CLI export yet.
