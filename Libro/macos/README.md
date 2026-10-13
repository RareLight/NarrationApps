# Libro for macOS — native development

The checked-in project uses **Xcode 27.0, Apple Silicon and Swift 6**. The app and its embedded worker target macOS 27; core fixtures keep their independent deployment minimum. The window imports mixed documents/folders, previews extracted text, remembers chosen workspace/output folders and generates audio through isolated native workers. It supports explicit model preparation, automatic/serial generation, cancellation, replacement, playback/reveal and private batch completion alerts. The Python CLI is independent.

## Build and open

```bash
bash macos/scripts/prepare-dependencies.sh
open macos/Libro/Libro.xcodeproj
```

Select the shared `Libro` scheme. `LibroSpeechWorker` is also shared and launches a Metal probe; `LibroCoreTests` builds the core fixtures separately. The app embeds the worker, signed Metal library, worker Swift compatibility libraries and native LAME MP3 encoder. Preparation builds the pinned codec from source with Xcode's compiler; no Python, Homebrew or global encoder is used. Ad-hoc development signing is the default; Developer ID, hardened-runtime acceptance and notarization are separate distribution work.

The reproducible terminal build keeps package clones, caches, modules and DerivedData under `macos/.build/` and forces arm64 for the package graph:

```bash
bash macos/scripts/build.sh -onlyUsePackageVersionsFromResolvedFile build
LIBRO_CONFIGURATION=Release bash macos/scripts/build.sh -onlyUsePackageVersionsFromResolvedFile -jobs 4 build
open macos/.build/DerivedData/Build/Products/Debug/Libro.app
```

To archive the app with the same local caches and existing signing configuration:

```bash
LIBRO_CONFIGURATION=Release bash macos/scripts/build.sh -onlyUsePackageVersionsFromResolvedFile -jobs 4 \
  -archivePath "$PWD/macos/.build/Archives/Libro.xcarchive" archive
```

The Metal embedding phase declares the physical package resource path during
Archive, where Xcode's ordinary products path is a symlink into `UninstalledProducts`.
Script sandboxing stays enabled for both Build and Archive.

When moving the checkout from another Mac or VM, leave `macos/.build/` behind
and run preparation again on the destination. SwiftPM state, shared Git object
stores, compiler caches and DerivedData can contain absolute paths to the old
checkout. Copying them can cause `Missing package product` errors even though
the project's package references are relative. If already copied, preserve the
old `.build` directory outside the active build path before preparing a fresh
one; it can contain local dependency edits and acceptance artifacts. Keep the
checked-in `Package.resolved` and recorded patches. In Xcode, reopen the project,
choose **File > Packages > Resolve Package Versions**, select the `Libro` scheme
and use Release for the build action. The terminal Release command above builds
`macos/.build/DerivedData/Build/Products/Release/Libro.app`.

If `xcrun metal --version` says the Metal Toolchain is missing, use Apple's `xcodebuild -downloadComponent MetalToolchain`. It was installed for this machine's first native build. Do not replace the selected Xcode or the CLI environment.

## Fast fixtures

```bash
bash macos/scripts/check.sh
```

These cover defaults/assets, atomic audio transactions, exact Float32 WAV samples, AAC containers/levels, format persistence/planning, recursive intake/deduplication, extraction, Unicode chunk coverage, output conflicts/aliases, bookmark restoration/recovery and real process orchestration using a model-free Swift helper. The process fixtures exercise ordering/backpressure, retries, malformed control/audio, crashes, bounded shutdown and cancellation. They do not run MLX or establish speech/GUI acceptance. Xcode's test action may require a macOS privacy prompt for its test runner to access a checkout on Desktop/Documents. SwiftPM's fixtures can run independently; do not alter OS permissions silently. The fixture helper is a development product and is not embedded in the app.

Include the prepared native MP3 codec in the fixture gate:

```bash
LIBRO_TEST_MP3_LIBRARY="$PWD/macos/.build/codecs/lame/lib/libmp3lame.0.dylib" bash macos/scripts/check.sh
```

After changing acquisition or updating the Hub SDK, also run its controlled
HTTP fixtures against the recorded workspace-download patch:

```bash
bash macos/scripts/check-downloads.sh
```

This separate package uses the app's exact local SDK and pinned transitive
dependencies. Initial dependency setup needs networking; its tests intercept
HTTP with fixtures and do not download models or run MLX. They cover partial
resumption, cancellation, ignored/malformed ranges, incomplete responses,
metadata failures, storage obstruction, symlinks and concurrent cache reuse.

The **Output format** picker offers WAV (default), M4A AAC-LC, M4B AAC-LC audiobook and MP3. The selection is remembered across launches; changes during processing apply to the next batch. WAV is uncompressed 32-bit floating-point PCM at the model's original sample rate, preserving its samples exactly without clipping or 16-bit conversion. AAC uses 64 kbps mono; MP3 uses 128 kbps mono. Both are lossy and receive the same original floats with no loudness normalization, compression, gain adjustment or ReplayGain/Sound Check tags. See [audio fidelity and format acceptance](../docs/native-gui-audio-formats.md) for the audit and separate fixture/build/speech/Apple Books evidence.

The shared importer ignores unsupported types, skips recursive symlinks/aliases/packages and includes ordinary hidden documents. Recursive discovery skips an incidental nested output subtree; explicitly selected files or folders inside the output directory are accepted, including when input and output share a folder. Selected supported files that fail extraction have visible errors. Foundation Markdown projection keeps block boundaries, reads code/link labels/image descriptions as text, and fetches no remote resources. PDF narration follows PDFKit's extracted page order; columns/headers and scanned content need operator review.

Create disposable operator fixtures with native document APIs (the destination must be empty):

```bash
swift macos/scripts/prepare-intake-fixtures.swift "$PWD/macos/.build/acceptance/intake"
```

See `../docs/native-gui-m2-acceptance.md` for folder recovery/planning checks and `../docs/native-gui-m4-acceptance.md` for GUI generation/lifecycle evidence and remaining operator acceptance. Choose a workspace and output, explicitly Prepare Model if assets are unavailable, resolve any name conflicts, then Generate Audio. Preparation shows the exact model/revision and byte progress, supports cancellation and keeps completed asset files for reuse. Existing audio needs one batch replacement choice. Changes and additions during processing apply to the next batch; the current destination stays visible. Closing the window continues processing; quitting during generation or preparation offers cancellation and waits for owned workers. Alerts respect macOS authorization; denied permission leaves results in the window.

## Workflow and troubleshooting

The compact window keeps narration choices above a three-column queue and the
remembered destination beside Generate Audio. Use **Settings > Models** for the
Libro workspace, explicit model preparation and exact repository/revision.
**Settings > Advanced** contains the remembered serial override, debug logging,
worker verification and completion-alert status. WAV remains the default format.
Kokoro defaults to Heart (`af_heart`) at 1.1×. Its voice menus sort the available
English voices by upstream overall grade, with alphabetical ties and starred
voices above a divider (Heart, Bella, Emma and Nicole). Menu labels show names
and stars only. See [voice ranking and sources](../docs/native-kokoro-voices.md).
During generation, current-batch choices and destination remain immutable;
open **Next Batch Settings…** to change later work. **Queue Again** adds an
unfinished document to the next batch rather than immediately generating it.
Preview is available through selection controls, double-click, context menus and
Command-Y. Press Return or Escape after editing an output name to return focus to
the queue. See [the UX checklist](../docs/native-gui-ux-checklist.md) for evidence
and the prepared operator acceptance pass.

For troubleshooting, choose **Libro > Settings… > Advanced > Enable debug logging** before retrying. Failed rows have **Details**; logs can be opened/revealed from Settings and stay under the selected workspace's `models/.native/diagnostics/` with bounded rotation. Logging defaults to off and may retain private upstream messages. See `../docs/native-gui-debugging.md` for use, evidence and the reproducible backport correcting the Xcode Metal-validation crash. Preparation installs the recorded Misaki, MLX and Hub SDK patches; rebuild the app after dependency corrections.

Native workers use a 64 MiB MLX free-buffer cache and a 1 GiB working-memory
threshold, clearing unused buffers between chunks. The coordinator watches each
helper's footprint and stops it above the smaller of 3 GiB or one quarter of
physical RAM, without automatically retrying that memory failure. Existing
complete audio survives. The MLX threshold is not a hard allocation cap; see
[the memory investigation](../docs/native-memory-2026-10-12.md) for measurements,
the sampled guard and remaining exported-app acceptance.

## Opt-in real speech

After changing the recorded engine compatibility patches, build both
configurations and run `bash macos/scripts/check-engine-api.sh` (repeat with
`LIBRO_CONFIGURATION=Release`). These compile fixtures exercise cache ownership
against the actual engine APIs; they do not run those models. Also run
`bash macos/scripts/check-engine-behavior.sh` in both configurations for optional
getters, text encodings and async task-local restoration against the built
package objects. See
[the dependency record](DEPENDENCIES.md) for the Metal language/build minimum
and the reproducible warning fixes.
The supplied Xcode warnings and the subsequent upstream warning cleanup are
recorded in [the October 11 warning audit](../docs/native-build-warnings-2026-10-11.md).

Preparation first validates compatible primary snapshots read-only at the existing `models/kokoro/mlx-community__Kokoro-82M-bf16` and `models/soprano/mlx-community__Soprano-1.1-80M-bf16` paths. It never rewrites the Python manifest. Otherwise it acquires pinned primary assets into `models/.native/primary/`; required English G2P assets live under `models/.native/assets/`. Native completion metadata, staging, locks and SDK caches are all under `models/.native/`. The recorded Hub SDK adaptation streams transfer bytes into private `.incomplete` blobs there and resumes received prefixes using the SDK's existing Range/cache flow. Missing metadata fails explicitly instead of falling back to OS download scratch. See `../docs/native-gui-m5-acceptance.md` for distinct fixture, real-download and remaining GUI acceptance gates.

Use the explicit preparation action or opt-in native acceptance harness, then generate offline. Supply absolute paths for the worker, selected Libro workspace and chosen sample output directory:

```bash
WORKER="$PWD/macos/.build/DerivedData/Build/Products/Debug/Libro.app/Contents/Helpers/LibroSpeechWorker"
swift build --package-path macos/LibroCore --scratch-path macos/.build/CoreTests --product LibroNativeCheck
macos/.build/CoreTests/debug/LibroNativeCheck "$WORKER" "$PWD" kokoro prepare
macos/.build/CoreTests/debug/LibroNativeCheck "$WORKER" "$PWD" soprano prepare
macos/.build/CoreTests/debug/LibroNativeCheck "$WORKER" "$PWD" "$PWD/macos/.build/acceptance/offline" serial --offline
```

For download recovery acceptance, use a disposable empty workspace with
`prepare --workspace-writes-only --cancel-after-bytes=20000000`. The harness
blocks worker writes outside that workspace and cancels during received-byte
progress; rerun without the cancellation option to resume. Set
`LIBRO_CHECK_DEBUG_LOG=1` for asset-level `resumedBytes` evidence. Use
`--offline --workspace-writes-only` for the final complete-inventory reuse
check. These options affect only the opt-in harness.

The offline harness uses `sandbox-exec` to block networking and native/CLI/global HF cache access in each fresh worker. Both explicit primary and prepared G2P directories must be complete. Workers spool bounded float32 audio under `models/.native/staging/`; the harness validates it and uses the shared atomic Float32 WAV writer. `serial` retains the M1 short one-shot sample check, public golden `.f32` streams and metadata/diagnostics for listening, and checks every decoded WAV sample bit against its worker output. Soprano is stochastic, so frame counts/audio bytes can differ between runs.

For the production coordinator/IPC path, replace `serial` with `batch`. This prepares a longer public Markdown sample and verifies automatic two-worker, ordered multi-chunk generation for both engines. The protocol loads a model once per worker for the current document, bounds dispatch to twelve chunks, retries eligible parallel failures once serially, revalidates destinations before atomic publication and reaps helpers before cleaning attempt staging. See `../docs/native-gui-m3-acceptance.md` for the distinct fixture/build/real-speech evidence.

`LIBRO_CHECK_OUTPUT_FORMAT=m4a`, `m4b` or `mp3` selects another format for the opt-in `batch` harness. MP3 uses the library embedded alongside the supplied packaged worker. The serial fidelity check always uses WAV.

For relocation testing, copy the built app, native harness and either compatible K/S primary directories or complete native primary snapshots, plus the prepared native auxiliary directory, to another workspace. Keep relative inventory paths intact. Omit `.venv` and all HF caches. `LIBRO_CHECK_DENY_ROOT=/absolute/original/checkout` additionally denies source-checkout reads inside offline workers. This diagnostic does not grant sandboxed-app bookmark access; Finder/privacy/bookmark GUI acceptance remains open.

See `DEPENDENCIES.md` for exact graph/asset pins, the narrow prepared-directory Misaki patch, update procedure and notices. Reverting native files and the native ignore rules removes this slice without changing the CLI installation. Do not include the GUI in today's portable CLI export yet.
