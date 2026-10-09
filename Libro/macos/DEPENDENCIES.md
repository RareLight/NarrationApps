# Native dependency record

This is a native Swift runtime. Python, the CLI environment and Homebrew are not native build or runtime dependencies.

- Xcode: 27.0 (27A266a), Swift 6.4 (swiftlang-6.4.0.34.1).
- Apple Silicon (`arm64`), Swift 6 language mode and complete concurrency checks in Libro targets. Shared deployment configuration is macOS 15.0; the current local app's macOS 27.0 override is preserved.
- MLX Audio Swift: `8d86630ade569728aaea3dc1a29fc44e2efa719b`, https://github.com/Blaizzy/mlx-audio-swift.
- MLX Swift: 0.31.4 (`dc43e62d7055353c7f99fa071a4e71d29dfddc44`), root-local checkout with the recorded Metal backport below. Its MLX core remains `ce45c52505c8158ea48d2a54e8caae05efd86bfe`; MLX C remains `0726ca922fc902c4c61ef9c27d94132be418e945`.
- MLX Swift LM: 3.31.4 (`bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57`).
- Swift Transformers: 1.1.9 (`150169bfba0889c229a2ce7494cf8949f18e6906`).
- Swift Hugging Face: 0.8.1 (`de01c0ab8fd537bbd8216cea7f774275178501a2`).
- The complete 30-package remote graph is retained in `Libro/Libro.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. MLX Audio and MLX Swift are local checkouts pinned by `scripts/prepare-dependencies.sh`; root-local MLX Swift also supplies all transitive MLX consumers. Moving MLX Swift local preserves every remaining remote pin.

## Narrow upstream adaptation

`Patches/misaki-local-resources.patch` changes only `MisakiTextProcessor`: an optional prepared resource directory in its initializer, and a return from `prepare()` when supplied. The existing zero-argument initializer retains upstream behavior. Libro validates the complete directory before constructing the processor. No G2P implementation, normalization, weights or configuration is changed.

Why this is required: at the pinned revision, Misaki's convenience acquisition calls `ModelUtils.resolveOrDownloadModel`, whose cache shortcut requires a valid `config.json`. The pinned `beshkenadze/kitten-tts-g2p` repository supplies `us_bart_config.json`, `us_bart.safetensors`, `us_gold.json`, `us_silver.json`, and **no `config.json`**. It also lacks a public strict offline/prepared-directory option. The adapter avoids this acquisition path completely during speech.

Update procedure: change the engine pin deliberately, inspect local loader/G2P changes, rebase the small patch, resolve and retain the full dependency graph, then repeat fixtures, Debug/Release packaged probes, both real models and blocked-network/missing/corrupt-asset tests. Never patch a floating package checkout.

`Patches/mlx-empty-vector-metal.patch` backports the `set_vector_bytes` guard from [upstream MLX commit 08298bbb](https://github.com/ml-explore/mlx/commit/08298bbbdfbf932378b9db9e3a2aa67ea97c94c4), adapting only the encoder accessor to this older core. Nonempty vectors retain the existing binding. Empty metadata binds one zero-initialized value instead of a null pointer; the zero-rank kernel specialization does not read that metadata. This prevents the `bytes argument cannot be nil` assertion under Xcode Metal API validation without disabling validation or upgrading the graph. Other changes in that upstream commit are not included.

Preparation verifies the parent and submodule revisions and the exact recorded diffs, refuses unexpected edits/untracked files, and is idempotent. Keep the checked-in backport and local root package reference together. A fresh checkout must run preparation before opening Xcode. When deliberately updating MLX, inspect whether the new core already contains the guard, remove/rebase the patch accordingly, and repeat real K/S generation with `MTL_DEBUG_LAYER=1` in both configurations. The worker probe includes arithmetic and non-leading scalar gather; a passing probe alone does not establish speech acceptance.

## Native MP3 codec

AAC-LC uses Apple's system encoder through AVFoundation. The local `AudioFormatGetProperty(kAudioFormatProperty_EncodeFormatIDs)` probe confirmed that macOS supplies no MP3 encoder, so MP3 uses [LAME 3.100](https://lame.sourceforge.io/download.php) as an arm64 dynamic library. This is a native C dependency, with no Python or external encoder process.

`scripts/prepare-codecs.sh` acquires the official `lame-3.100.tar.gz` release from SourceForge and verifies SHA-256 `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`. It builds under `macos/.build/codecs/` with the selected Xcode compiler and macOS 15 deployment target. `Patches/lame-export-symbols.patch` removes only the obsolete `lame_init_old` export that prevents the release's shared library from linking; no codec implementation is changed. Decoder symbols remain enabled to satisfy the upstream export list; Libro disables on-the-fly decoding and ReplayGain. The frontend and static library are disabled.

Preparation stamps the compiler/script/patch identity and verifies the cached library's digest. Xcode's standard Copy Files phase embeds and signs `libmp3lame.0.dylib` under `Contents/Frameworks/`. Libro opens that exact path lazily for MP3; there is no global-library search. Each output owns its codec state. Unity scale, the IEEE Float32 API, original sample rate, mono 128 kbps and disabled ReplayGain preserve the submitted levels without an integer intermediate. MP3 itself is lossy.

LAME is LGPL-licensed. Its `COPYING` and `README` are retained under `macos/.build/notices/lame/`, alongside the verified source archive and patched source build directory. Public distribution must include the applicable notices and corresponding-source/relinking arrangements; the existing distribution gate remains open. When updating, deliberately change the release/digest, review or remove the export patch, rebuild, then repeat codec level/metadata/cancellation fixtures, Debug/Release signing and actual speech exports. The Swift graph is unchanged by this codec addition.

## Native assets

Kokoro primary: existing `mlx-community/Kokoro-82M-bf16`, default `af_aoede`, speed 1.1. Soprano primary: existing `mlx-community/Soprano-1.1-80M-bf16`; retain that exact repository hint in its local loader. Existing primary directories and Python manifests are read-only.

English native G2P: `beshkenadze/kitten-tts-g2p` revision `9c692b92682d959d9013a9cfe6a49541997add18`. Required inventory:

| File | Bytes |
| --- | ---: |
| us_bart.safetensors | 3011692 |
| us_bart_config.json | 1257 |
| us_gold.json | 3001196 |
| us_silver.json | 3105352 |

The preparation action uses `HubClient`/`HubCache`, exact revision and file allowlist, with a workspace-local cache. It records SHA-256 digests and checks the published LFS digest of the weight. Runtime rechecks required files, sizes, JSON and all digests. The upstream British fallback uses these US assets when GB resources are absent; broader voice/pronunciation acceptance remains open.

All native caches, locks, inventories, staging and auxiliary resources are under the selected workspace's `models/.native/`. No weights belong in the signed app bundle. No narration text is passed to acquisition APIs. Initial preparation covers G2P only; primary native acquisition is an M5 gate.

## Notices

MLX Audio Swift, MLX Swift and its LM libraries use MIT licenses. The prepared G2P model card declares MIT. The complete dependency licenses must accompany distribution, including transitive packages and model notices; build feasibility does not close the distribution review. Upstream notices remain in the exact source checkouts. `scripts/collect-notices.sh` captures license/notice files in ignored local build artifacts for review.
