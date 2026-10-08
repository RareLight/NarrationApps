# Libro for macOS — native development

The checked-in project uses **Xcode 27.0, Apple Silicon and Swift 6**. Shared configuration proposes macOS 15+, but the current local Xcode project has an app deployment override of macOS 27.0; that existing edit is preserved. The window imports mixed documents/folders, previews extracted text, remembers chosen workspace/output folders and generates WAVs through isolated native workers. It supports explicit model preparation, automatic/serial generation, cancellation, replacement, playback/reveal and private batch completion alerts. The Python CLI is independent.

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

These cover defaults/assets, atomic PCM16 transactions, recursive intake/deduplication, extraction, Unicode chunk coverage, output conflicts/aliases, bookmark restoration/recovery and real process orchestration using a model-free Swift helper. The process fixtures exercise ordering/backpressure, retries, malformed control/audio, crashes, bounded shutdown and cancellation. They do not run MLX or establish speech/GUI acceptance. Xcode's test action may require a macOS privacy prompt for its test runner to access a checkout on Desktop/Documents. SwiftPM's fixtures can run independently; do not alter OS permissions silently. The fixture helper is a development product and is not embedded in the app.

The shared importer ignores unsupported types, skips recursive symlinks/aliases/packages and includes ordinary hidden documents. Recursive discovery skips an incidental nested output subtree; explicitly selected files or folders inside the output directory are accepted, including when input and output share a folder. Selected supported files that fail extraction have visible errors. Foundation Markdown projection keeps block boundaries, reads code/link labels/image descriptions as text, and fetches no remote resources. PDF narration follows PDFKit's extracted page order; columns/headers and scanned content need operator review.

Create disposable operator fixtures with native document APIs (the destination must be empty):

```bash
swift macos/scripts/prepare-intake-fixtures.swift "$PWD/macos/.build/acceptance/intake"
```

See `../docs/native-gui-m2-acceptance.md` for folder recovery/planning checks and `../docs/native-gui-m4-acceptance.md` for GUI generation/lifecycle evidence and remaining operator acceptance. Choose a workspace and output, explicitly Prepare Model if assets are unavailable, resolve any name conflicts, then Generate Audio. Preparation shows the exact model/revision and byte progress, supports cancellation and keeps completed asset files for reuse. Existing audio needs one batch replacement choice. Changes and additions during processing apply to the next batch; the current destination stays visible. Closing the window continues processing; quitting during generation or preparation offers cancellation and waits for owned workers. Alerts respect macOS authorization; denied permission leaves results in the window.

## Opt-in real speech

For troubleshooting, choose **Libro > Settings… > Enable debug logging** before retrying. Failed rows have **Details**; logs can be opened/revealed from Settings and stay under the selected workspace's `models/.native/diagnostics/` with bounded rotation. Logging defaults to off and may retain private upstream messages. See `../docs/native-gui-debugging.md` for use, evidence and the reproducible backport correcting the Xcode Metal-validation crash. Preparation installs both recorded dependency patches; rebuild the app after dependency corrections.

Preparation first validates compatible primary snapshots read-only at the existing `models/kokoro/mlx-community__Kokoro-82M-bf16` and `models/soprano/mlx-community__Soprano-1.1-80M-bf16` paths. It never rewrites the Python manifest. Otherwise it acquires pinned primary assets into `models/.native/primary/`; required English G2P assets live under `models/.native/assets/`. Native completion metadata, staging, locks and persistent SDK caches are all under `models/.native/`. The SDK temporarily receives downloads in macOS system temporary storage; acceptance of that transfer scratch and interrupted-file byte resumption remain open M5 gates. See `../docs/native-gui-m5-acceptance.md` before treating acquisition as fully accepted.

Use the explicit preparation action or opt-in native acceptance harness, then generate offline. Supply absolute paths for the worker, selected Libro workspace and chosen sample output directory:

```bash
WORKER="$PWD/macos/.build/DerivedData/Build/Products/Debug/Libro.app/Contents/Helpers/LibroSpeechWorker"
swift build --package-path macos/LibroCore --scratch-path macos/.build/CoreTests --product LibroNativeCheck
macos/.build/CoreTests/debug/LibroNativeCheck "$WORKER" "$PWD" kokoro prepare
macos/.build/CoreTests/debug/LibroNativeCheck "$WORKER" "$PWD" soprano prepare
macos/.build/CoreTests/debug/LibroNativeCheck "$WORKER" "$PWD" "$PWD/macos/.build/acceptance/offline" serial --offline
```

The offline harness uses `sandbox-exec` to block networking and native/CLI/global HF cache access in each fresh worker. Both explicit primary and prepared G2P directories must be complete. Workers spool bounded float32 audio under `models/.native/staging/`; the harness validates it and uses the shared atomic PCM16 WAV writer. `serial` retains the M1 short one-shot sample check and metadata/diagnostics for listening. Soprano is stochastic, so frame counts/audio bytes can differ between runs.

For the production coordinator/IPC path, replace `serial` with `batch`. This prepares a longer public Markdown sample and verifies automatic two-worker, ordered multi-chunk generation for both engines. The protocol loads a model once per worker for the current document, bounds dispatch to twelve chunks, retries eligible parallel failures once serially, revalidates destinations before atomic publication and reaps helpers before cleaning attempt staging. See `../docs/native-gui-m3-acceptance.md` for the distinct fixture/build/real-speech evidence.

For relocation testing, copy the built app, native harness and either compatible K/S primary directories or complete native primary snapshots, plus the prepared native auxiliary directory, to another workspace. Keep relative inventory paths intact. Omit `.venv` and all HF caches. `LIBRO_CHECK_DENY_ROOT=/absolute/original/checkout` additionally denies source-checkout reads inside offline workers. This diagnostic does not grant sandboxed-app bookmark access; Finder/privacy/bookmark GUI acceptance remains open.

See `DEPENDENCIES.md` for exact graph/asset pins, the narrow prepared-directory Misaki patch, update procedure and notices. Reverting native files and the native ignore rules removes this slice without changing the CLI installation. Do not include the GUI in today's portable CLI export yet.
