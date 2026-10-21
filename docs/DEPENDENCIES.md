# Native dependency record

Package-relative paths in this record (`scripts/`, `Patches/`, `Sources/`,
`Package.resolved` and `.build/`) are relative to `NarrationApps/swift-packages`,
which contains the maintained packages and their preparation tools. The parent
repository owns the workspace and this documentation.

This is a native Swift runtime. Python, the CLI environment and Homebrew are not native build or runtime dependencies.

- Current development toolchain: stable Xcode 27.1 (27A9275), macOS 27.0 SDK, Swift 6.4 (swiftlang-6.4.0.34.1). Earlier automated evidence used Xcode 27.2 beta (27B5028f)/macOS 27.2 SDK. Current workspace validation is recorded separately; earlier results are not silently attributed to the replacement toolchain.
- Apple Silicon (`arm64`), Swift 6 language mode and complete concurrency checks in Libro targets. The app and embedded worker target macOS 27.0. Shared library and app fixtures target macOS 27.0.
- MLX Audio Swift: `8d86630ade569728aaea3dc1a29fc44e2efa719b`, https://github.com/Blaizzy/mlx-audio-swift.
- MLX Swift: 0.31.4 (`dc43e62d7055353c7f99fa071a4e71d29dfddc44`), root-local checkout with the recorded Metal backport below. Its MLX core remains `ce45c52505c8158ea48d2a54e8caae05efd86bfe`; MLX C remains `0726ca922fc902c4c61ef9c27d94132be418e945`.
- MLX Swift LM: 3.31.4 (`bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57`), local checkout with the manifest adaptation below.
- Swift Transformers: 1.1.9 (`150169bfba0889c229a2ce7494cf8949f18e6906`).
- Swift Hugging Face: 0.8.1 (`de01c0ab8fd537bbd8216cea7f774275178501a2`), root-local checkout with the workspace-download adaptation below.
- Remote pins are retained in this repository’s `Package.resolved`; each consumer also retains its own resolved graph. MLX Audio, MLX Swift, MLX Swift LM and Swift Hugging Face are local checkouts pinned by preparation scripts. Their manifests use the same sibling locations throughout the graph, avoiding SwiftPM's conflicting local/remote identity warning. Controlled Hub SDK fixtures now live in the shared HubDownloadTests target.

## EPUB container dependency

[ZIPFoundation](https://github.com/weichsel/ZIPFoundation) is pinned exactly to
**0.9.20**, commit `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` (MIT).
`scripts/prepare-zipfoundation.sh` prepares that exact revision at
`.build/dependencies/ZIPFoundation`; the root manifest consumes this local checkout.
`Patches/zipfoundation-watchos-minimum.patch` raises only the manifest's unsupported
watchOS 2/4 declarations to 9.0, removing the stable-Xcode deprecation warning.
Archive source, the macOS minimum, Compression and public APIs are unchanged.
The audited preparation helper rejects unrelated changes and is idempotent.
ZIPFoundation's revision is now recorded by the preparation script, rather than a
remote Package.resolved entry. Existing upstream notices remain applicable.

DocumentProcessing uses its native archive reader with Apple's Compression on
macOS; no subprocess, archive extraction to disk or new transitive dependency is
added. The upstream license is retained in `ThirdPartyNotices/ZIPFoundation/` and
collected into app notices. Other remote dependency pins remain in consumer resolution files.

The small EPUB adapter uses existing Foundation XMLParser and SwiftSoup for
[EPUB 2/3 OCF/package/spine semantics](https://www.w3.org/TR/epub-33/).
EPUBKit 0.5.0 was evaluated but requires `spine.toc`/NCX and extracts the whole
archive through additional parser/ZIP dependencies. Its stable API therefore did
not fit valid EPUB 3 nav-only books or this bounded, memory-only intake boundary.
The adapter implements reading-order narration, notes and embedded descriptions;
it does not add a general ebook renderer or DRM implementation. Existing PDF and
HTML dependencies/pins are unchanged.

## Narrow upstream adaptation

`Patches/mlx-audio-build-compatibility.patch` and
`Patches/mlx-lm-local-dependency.patch` retain the exact engine revisions above.
They use local sibling dependencies and align their macOS minimum with MLX's
Metal resource build. The audio patch also replaces deprecated API spellings:
Breeze reads the same default quantization from `perLayerQuantization`, Irodori
explicitly retains `.affine`, and BiLSTM uses `addMM`. Unchanged bindings become
`let`. Llama/Qwen stream APIs accept `sending` caches and transfer them into
Task's sending closure, instead of capturing non-Sendable caches in an explicit
`@Sendable` closure. Borrowed reference audio is materialized as copied bytes,
shape and dtype before the task starts; the task creates its own MLX array.
Cache aliases must not be used after transfer. This does not
assert that cache/model instances are safe for concurrent inference; Libro's
Kokoro/Soprano state remains confined to separate worker processes.

`Patches/mlx-metal4-platform.patch` changes only the local MLX manifest's macOS
minimum to 26.0. Xcode chooses Metal 4.0 for those package resources, which
supports the pinned attention headers' `if constexpr`. Metal 3.1/3.2 probes
reproduced all four extension warnings; Metal 4.0 compiled the same headers
without them. Project-level Metal settings do not propagate to SwiftPM packages.
Using a package minimum of 27.0 selects Metal 4.1, whose stricter address-space
rules reject these pinned kernels; do not raise it blindly. This build minimum
does not lower the app/worker's macOS 27 requirement or modify kernel math.

`Patches/mlx-swift-warning-compatibility.patch` selects Swift 6.4's current
async TaskLocal overload using a `nonisolated(nonsending)` operation type.
`withoutActuallyEscaping` keeps the existing non-escaping public callback and
`rethrows` signatures; the operation is awaited within that lifetime. No
Sendable conformance or inference concurrency guarantee is added. MLXNN's
optional getters retain dynamic optional promotion through `Any`, and its
structural switch is exhaustive without an unreachable default.
`Patches/mlx-lm-encoding-detection.patch` uses Foundation's `usedEncoding`
reader, preserving automatic detection rather than assuming UTF-8.

`Patches/mlx-vendor-warning-policy.patch` disables only
`-Wshorten-64-to-32` for the vendored Cmlx C++ target on macOS. Xcode adds this
diagnostic to the pinned core whereas its upstream Darwin CMake build does
not. This is a deliberate vendor warning-policy exception for the 459
inventoried narrowing locations, not a claim that every conversion has been
made overflow-safe. No numerical/index code, audio levels, or other diagnostic
settings change. Keep the original inventory in the warning audit; when
updating MLX, review this exception against upstream's types and build policy
before rebasing/removing it. Do not apply it to Libro or Swift targets.

The app sets `COPY_PHASE_STRIP = NO`: the producer signs the helper and Xcode's
embedding phase copies and re-signs it without attempting to strip signed bytes.
Preparation validates exact recorded patch sequences, accepts clean checkouts
or previously recorded prefixes, and rejects unrelated edits before applying
anything. `scripts/check-preparation.sh` tests setup, idempotence, migration and
preservation of unexpected edits in disposable Git fixtures.
Set `NARRATION_DERIVED_DATA` to a built consumer checkout's DerivedData; for
Archive also set `NARRATION_PRODUCTS_DIRECTORY` and `NARRATION_WORKER_OBJECTS`
to its Archive build products and helper LinkFileList. Set\n`NARRATION_MODULE_MAPS` to the Archive intermediate GeneratedModuleMaps folder. Optional
`NARRATION_PACKAGE_CHECKOUTS` selects its resolved C module-map checkouts.
`NARRATION_CONFIGURATION=Release` chooses Release.
After a packaged build, `scripts/check-engine-api.sh` compiles valid cache
transfers against the actual patched APIs with Swift 6 complete checks and
warnings as errors, and requires the compiler to reject post-transfer aliases
for both stream APIs. These are compile fixtures, not Llama/Qwen speech tests.
`scripts/check-engine-behavior.sh` links the actual built package objects and
compiles its fixtures with Swift 6 complete checks and warnings as errors.
It checks optional parameter/module initialization, tree traversal, TXT/JSONL
UTF-8 and UTF-16 LE/BE detection, and async device/stream/random-state scopes
through suspension, nesting, child inheritance, errors and cancellation.
It evaluates small fixture arrays with Metal validation and does not load a
speech model. Repeat both scripts in Debug and Release after these adaptations.

`Patches/misaki-local-resources.patch` changes only `MisakiTextProcessor`: an optional prepared resource directory in its initializer, and a return from `prepare()` when supplied. The existing zero-argument initializer retains upstream behavior. Libro validates the complete directory before constructing the processor. No G2P implementation, normalization, weights or configuration is changed.

Why this is required: at the pinned revision, Misaki's convenience acquisition calls `ModelUtils.resolveOrDownloadModel`, whose cache shortcut requires a valid `config.json`. The pinned `beshkenadze/kitten-tts-g2p` repository supplies `us_bart_config.json`, `us_bart.safetensors`, `us_gold.json`, `us_silver.json`, and **no `config.json`**. It also lacks a public strict offline/prepared-directory option. The adapter avoids this acquisition path completely during speech.

Update procedure: change the engine pin deliberately, inspect local loader/G2P changes, rebase the small patch, resolve and retain the full dependency graph, then repeat fixtures, Debug/Release packaged probes, both real models and blocked-network/missing/corrupt-asset tests. Never patch a floating package checkout.

`Patches/mlx-empty-vector-metal.patch` backports the `set_vector_bytes` guard from [upstream MLX commit 08298bbb](https://github.com/ml-explore/mlx/commit/08298bbbdfbf932378b9db9e3a2aa67ea97c94c4), adapting only the encoder accessor to this older core. Nonempty vectors retain the existing binding. Empty metadata binds one zero-initialized value instead of a null pointer; the zero-rank kernel specialization does not read that metadata. This prevents the `bytes argument cannot be nil` assertion under Xcode Metal API validation without disabling validation or upgrading the graph. Other changes in that upstream commit are not included.

Preparation verifies the parent and submodule revisions and the exact recorded diffs, refuses unexpected edits/untracked files, and is idempotent. Keep the checked-in backport and local root package reference together. A fresh checkout must run preparation before opening Xcode. When deliberately updating MLX, inspect whether the new core already contains the guard, remove/rebase the patch accordingly, and repeat real K/S generation with `MTL_DEBUG_LAYER=1` in both configurations. The worker probe includes arithmetic and non-leading scalar gather; a passing probe alone does not establish speech acceptance.

`Patches/hub-workspace-downloads.patch` adds the opt-in Darwin
`downloadInCache` argument to the SDK's LFS file API. Libro enables it; upstream
default behavior remains unchanged. The existing request/authentication,
immutable revision, metadata, Range and cache-lock flows remain in the SDK.
Serialized URLSession data callbacks write received buffers directly into its
workspace-local incomplete blob. Cancellation/network failure retain that
prefix; valid 206 responses append, ignored Range/200 responses replace it,
and 416 resets it. Missing metadata fails instead of using OS download scratch.
No download task or whole-file Data buffer is used in this path. Libro still
validates every staged file against its pinned length and SHA-256 before
publishing an inventory. It also quarantines invalid orphan blobs before SDK
reuse. This is a storage adaptation to the pinned SDK, not a second HTTP/cache
manager.

`scripts/prepare-hub.sh` verifies the revision and exact patch and preserves
unexpected edits. On a deliberate SDK update, inspect its native streaming,
Range and cache publication behavior before rebasing/removing this patch.
Keep the Xcode local reference and preparation pin together. Update the fixture
lock intentionally and run `bash macos/scripts/check-downloads.sh`, core
fixtures, both packaged builds, interrupted real acquisition with
`--workspace-writes-only`, offline inventory reuse and real K/S speech. SDK
fixture HTTP never leaves the process; initial package setup may fetch source
dependencies. See [historical Metal recovery evidence](../Libro/docs/TROUBLESHOOTING.md).

## Native MP3 codec

AAC-LC uses Apple's system encoder through AVFoundation. The local `AudioFormatGetProperty(kAudioFormatProperty_EncodeFormatIDs)` probe confirmed that macOS supplies no MP3 encoder, so MP3 uses [LAME 3.100](https://lame.sourceforge.io/download.php) as an arm64 dynamic library. This is a native C dependency, with no Python or external encoder process.

`scripts/prepare-codecs.sh` acquires the official `lame-3.100.tar.gz` release from SourceForge and verifies SHA-256 `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`. It builds under `.build/codecs/` with the selected Xcode compiler and macOS 15 deployment target. `Patches/lame-export-symbols.patch` removes only the obsolete `lame_init_old` export that prevents the release's shared library from linking; no codec implementation is changed. Decoder symbols remain enabled to satisfy the upstream export list; Libro disables on-the-fly decoding and ReplayGain. The frontend and static library are disabled.

`Patches/lame-front-cover.patch` changes only the APIC picture-kind byte emitted
by the existing album-art API from Other (0) to Front Cover (3). It adds no tag
serializer and changes no audio sample, encoder math, bitrate, ReplayGain or
codec API. The pinned archive/release is unchanged. Preparation applies both
patches reproducibly and includes both digests in the cached build signature.
Audio regressions inspect the APIC MIME/type and compare MPEG packets/seek data.

Preparation stamps the compiler/script/patch identity and verifies the cached library's digest. Xcode's standard Copy Files phase embeds and signs `libmp3lame.0.dylib` under `Contents/Frameworks/`. Libro opens that exact path lazily for MP3; there is no global-library search. Each output owns its codec state. Unity scale, the IEEE Float32 API, original sample rate, mono 128 kbps and disabled ReplayGain preserve the submitted levels without an integer intermediate. MP3 itself is lossy.

LAME is LGPL-licensed. Its `COPYING` and `README` are retained under `.build/notices/lame/`, alongside the verified source archive and patched source build directory. Public distribution must include the applicable notices and corresponding-source/relinking arrangements; the existing distribution gate remains open. When updating, deliberately change the release/digest, review or remove the export patch, rebuild, then repeat codec level/metadata/cancellation fixtures, Debug/Release signing and actual speech exports. The Swift graph is unchanged by this codec addition.

## Native assets

Kokoro primary: pinned `mlx-community/Kokoro-82M-bf16`, default `af_heart` at 1.0×
with the accepted prepared-phoneme pause profile. Explicit saved settings remain
unchanged. Soprano primary: `mlx-community/Soprano-1.1-80M-bf16`; retain that exact
repository hint in its local loader. The product CLI/Python runtime is retired;
legacy private environments/manifests and existing model payloads remain preserved.

English native G2P: `beshkenadze/kitten-tts-g2p` revision `9c692b92682d959d9013a9cfe6a49541997add18`. Required inventory:

| File | Bytes |
| --- | ---: |
| us_bart.safetensors | 3011692 |
| us_bart_config.json | 1257 |
| us_gold.json | 3001196 |
| us_silver.json | 3105352 |

The preparation action uses `HubClient`/`HubCache`, exact revision and file allowlist, with a workspace-local cache. It records SHA-256 digests and checks the published LFS digest of the weight. Runtime rechecks required files, sizes, JSON and all digests. The unpatched upstream port substituted US files for missing GB resources. The recorded longform adaptation now rejects that substitution; British voices use the separately pinned inventory described below. Broader pronunciation acceptance remains open.

All native caches, locks, inventories, staging and auxiliary resources are under the selected workspace's `models/.native/`. Inventory replacement uses a synchronized private sibling and atomic rename, avoiding Foundation's OS replacement scratch. No weights belong in the signed app bundle. No narration text is passed to acquisition APIs. Explicit preparation covers the selected K/S primary inventory and required auxiliaries; CLI coexistence and remaining GUI relocation/operator gates stay separate.

## Notices

MLX Audio Swift, MLX Swift and its LM libraries use MIT licenses. The prepared G2P model card declares MIT. The complete dependency licenses must accompany distribution, including transitive packages and model notices; build feasibility does not close the distribution review. Upstream notices remain in the exact source checkouts. `scripts/collect-notices.sh` captures license/notice files in ignored local build artifacts for review.

## Longform frontend adaptation (October 15, 2026)

`Patches/kokoro-prepared-frontend.patch` exposes native Misaki token ranges without
Markdown phoneme directives and adds an explicit, strictly validated Kokoro
prepared-phoneme method. The accepted prepared method rejects unsupported scalars and
uses row `tokenCount - 1`; the legacy method remains available for comparison.
For af_heart, am_michael and bf_emma, the converted pinned `[510,1,256]` Float32
storage is byte-identical to the corresponding upstream `hexgrad/Kokoro-82M`
voice storage at `f3ff3571791e39611d31c381e3a41a3af07b4987`. Reference KPipeline
at `dfb907a02bba8152ca444717ca5d78747ccb4bec` selects length-minus-one.
No audible improvement is inferred from this format audit.

The same patch removes both silent British-to-US filename substitutions. British
voices require their separately validated inventory. US inventories/paths remain
unchanged. Explicit British preparation obtains the existing dictionaries and
native BART resources from `mlalma/MisakiSwift` commit
`b7477b15fc46cf8e20b32c008126611b38ec6b79`; exact sizes/SHA-256 values are in
`Sources/NativeSpeech/BritishG2P.swift`. Its Apache 2.0 license is retained in
`ThirdPartyNotices/MisakiSwift/LICENSE`. The BART architecture and native config
keys match the pinned port; regional execution/phoneme fixtures passed, while
actual pronunciation quality remains operator-owned.
No new model family, package dependency or maintained Python runtime is added.

The companion vocabulary and loaded-voice-shape patches expose only supported
symbols and validate the loader's squeezed `[510,256]` value. The BART input-bound
patch prevents positional-table overruns without truncating graphemes. The number
parity patch restores Misaki's dotted-letter acronym condition, splits numeric
word expansions at punctuation, and delegates cardinal/decimal spelling to Apple's
Foundation NumberFormatter instead of the incomplete custom grammar. The currency
tag patch reuses the lexicon's existing numeric predicate because Apple tags
decimal prices as OtherWord on this SDK. All changes remain recorded at the same
MLX Audio pin. `scripts/check-native-numbers.sh` compiles the actual patched
converter against independent English-word expectations without model assets;
`Tests/Fixtures/Longform/frontend.json` supplies native regional phoneme regressions.
Reference Misaki `en.py` is frozen at `fba1236595f2d2bf21d414ba6e57d25256afada3`.

## Aligned subtoken range correction (October 15, 2026)

`Patches/misaki-subtoken-ranges.patch` retains the regex match ranges when the
pinned English frontend splits a token. Each part now uses its actual UTF-16
source range, instead of copying the whole parent range. Dotted contents-page
leaders previously produced overlapping tokens and failed the strict coverage
validator before synthesis. The splitting regex, phoneme rules, vocabulary, model pin and
audio levels are unchanged; alignment checks remain strict. Prepared frontend
provenance advances to `misaki-aligned-3/subtoken-ranges-1`, so cached plans cannot
be mistaken for plans made with the previous range behavior. Legacy/Soprano
identities and existing sample recordings retain their recorded provenance.

Synthetic contents-page leaders and accented text are included in
`Tests/Fixtures/Longform/frontend.json` for actual offline US/GB frontend checks.
The supplied ebook and extracted text remain private diagnostic inputs, outside
source control.

## Maintenance procedure and ownership

Paths and commands in this maintenance section are relative to NarrationApps root.

Do not upgrade pins or retire patches merely to clean up warnings. The scripts
and patch files in `swift-packages/` are the maintained preparation implementation;
the inventory above records upstream revisions, licenses, purpose and provenance.

For an authorized dependency update:

1. Record exact upstream commit/tag, repository identity, release age, license and
   notice changes. Compare the existing ordered patch inventory with the upstream
   fix, including failure cases—not just whether a patch still applies. Review
   model/frontend/voice and offline-acquisition compatibility independently.
2. Use an isolated disposable source checkout with its own generated state. Never
   copy caches or reset a working dependency tree to force a match. Existing
   preparation must reject unexpected revisions, staged/untracked/private edits.
   Network source acquisition is explicit setup; speech-model acquisition is a
   separate operator action, never a build prerequisite.
3. Change the smallest pin/patch/notice set. Remove a patch only after its upstream
   replacement passes the original regression and relevant new cases. Preserve
   original notices and record why each patch is still needed.
4. Run preparation safety regressions, affected quick scopes, root full fixtures
   and both workspace configurations. Engine, frontend, admission, IPC, audio or
   model-resource changes additionally require prepared offline native checks.
   Packaging/lock/dependency changes require individual Archives and bundle checks
   through release. Operator quality/account/service gates stay separate.
5. Commit coordinated app adoption in the monorepo after validation; update
   toolchain metadata when it changes. The containing commit identifies both apps
   and packages; no app SHA pins are maintained. Keep reviewable evidence and
   publish only when authorized.

### Resolution files

Root owns the workspace lock and the shared package lock. Libro owns its core
package and standalone Xcode lock; VoiceRelay owns its package and standalone
Xcode lock. Each consumer resolves its own graph. The coordinated SwiftSoup,
swift-readability and swift-transformers revisions must agree where present;
`scripts/check-contracts.swift` detects incompatible drift across all six locks.
Different unrelated transitive graphs are allowed. Review actual resolver diffs;
never blindly overwrite every lock with another consumer's file.

### Compatibility and release evidence

Use focused imperative commits describing intent, retaining independent app
histories. The original coordinated milestone tag is immutable. Any future
release tag/version requires separately approved release scope; do not bump
current versions or rename compatibility identifiers for cosmetic consistency.
Public API, worker protocol, acoustic/frontend/prepared-plan and persisted record
versions are distinct. Incompatible changes need explicit migration/old-new
fixtures; optional additive fields must retain legacy decoding. Keep admission
lock aliases and accepted-policy identifiers that existing checkpoints require.
Finished/published recordings are not regenerated by a dependency update.

The release tier emits an ignored machine-readable evidence manifest
(`.local/validation/release-*/summary.json`): the containing monorepo commit ID and dirty
state, actual toolchain/SDK/architecture, lock/patch/resource/notice fingerprints,
prepared dependency revisions/diff fingerprints, per-bundle artifact digests and
signature class, gate outcomes/skips/unavailable steps, and evidence paths.
Generated reports can include root's actual SHA without a self-referential
source-manifest SHA. Ad-hoc evidence is not account/notarization acceptance.
Retain or deliberately publish reports only after privacy and provenance review.

Normal signing settings remain unchanged. Developer ID, notarization, clean-Mac,
installer/player, Keychain and live-service checks are human gates in the
[operator checklist](OPERATOR_VALIDATION.md) and the app release checklist.
No publication/export/registry activation is requested. Root has no Package.swift;
its bare URL is not a consumable SwiftNarration release. Patched ignored source
dependencies still require preparation. Future package-root export/registry work
is described in [package boundaries](PACKAGE_BOUNDARIES.md#management-and-independent-releases).
