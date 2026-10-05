# Native dependency record

This is a native Swift runtime. Python, the CLI environment and Homebrew are not native build or runtime dependencies.

- Xcode: 27.0 (27A266a), Swift 6.4 (swiftlang-6.4.0.34.1).
- Apple Silicon (`arm64`), macOS 15.0 deployment target, Swift 6 language mode and complete concurrency checks in Libro targets.
- MLX Audio Swift: `8d86630ade569728aaea3dc1a29fc44e2efa719b`, https://github.com/Blaizzy/mlx-audio-swift.
- MLX Swift: 0.31.4 (`dc43e62d7055353c7f99fa071a4e71d29dfddc44`).
- MLX Swift LM: 3.31.4 (`bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57`).
- Swift Transformers: 1.1.9 (`150169bfba0889c229a2ce7494cf8949f18e6906`).
- Swift Hugging Face: 0.8.1 (`de01c0ab8fd537bbd8216cea7f774275178501a2`).
- The complete 31-package remote graph is retained in `Libro/Libro.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. The adapted MLX Audio package is a local checkout pinned by `scripts/prepare-dependencies.sh`.

## Narrow upstream adaptation

`Patches/misaki-local-resources.patch` changes only `MisakiTextProcessor`: an optional prepared resource directory in its initializer, and a return from `prepare()` when supplied. The existing zero-argument initializer retains upstream behavior. Libro validates the complete directory before constructing the processor. No G2P implementation, normalization, weights or configuration is changed.

Why this is required: at the pinned revision, Misaki's convenience acquisition calls `ModelUtils.resolveOrDownloadModel`, whose cache shortcut requires a valid `config.json`. The pinned `beshkenadze/kitten-tts-g2p` repository supplies `us_bart_config.json`, `us_bart.safetensors`, `us_gold.json`, `us_silver.json`, and **no `config.json`**. It also lacks a public strict offline/prepared-directory option. The adapter avoids this acquisition path completely during speech.

Update procedure: change the engine pin deliberately, inspect local loader/G2P changes, rebase the small patch, resolve and retain the full dependency graph, then repeat fixtures, Debug/Release packaged probes, both real models and blocked-network/missing/corrupt-asset tests. Never patch a floating package checkout.

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
