# Contributing to NarrationApps

One repository owns `Libro/`, `VoiceRelay/`, `swift-packages/`, the Xcode workspace,
docs and project scripts. Shared fixes belong in the packages; app-specific
workflows remain in their directories. See [architecture](docs/ARCHITECTURE.md)
and [current status](docs/IMPLEMENTATION_STATUS.md) before changing behavior.

## Setup

Commands below run from the NarrationApps root unless a guide explicitly says
otherwise.

```sh
git clone git@github.com:RareLight/NarrationApps.git
cd NarrationApps
bash scripts/develop.sh health
```

Use Apple Silicon, macOS 27.0 or later, and Xcode with a macOS SDK supporting the
27.0 deployment target. Package manifests require Swift tools 6.2 or later;
[DevelopmentBaseline.json](DevelopmentBaseline.json) records the verified
Xcode 27.1 / Swift 6.4 / macOS 27.0 SDK composition. It is a tested checkpoint,
not a promise that every newer or older toolchain works with the pinned patches.
Ensure the intended Xcode is selected with `xcode-select -p`.

Health is offline and read-only. A fresh clone normally reports missing prepared
dependencies. Once network source acquisition is authorized, prepare and resolve:

```sh
bash scripts/develop.sh setup --resolve
bash scripts/develop.sh health
```

`--resolve` prepares pinned native sources, applies recorded patches, builds LAME
and resolves the workspace plus shared/LibroCore/VoiceRelay fixture graphs. It may
use the network; review lockfile diffs. `--prepare-dependencies` prepares sources
and LAME without resolving every graph. Neither action installs speech models.
`--clone-apps` is retired: both apps are already in the monorepo.

Check that the optional Metal compiler actually runs with `xcrun metal --version`;
`--find metal` alone may return a shim. If missing, use Xcode's component installer
(`xcodebuild -downloadComponent MetalToolchain`). If an installed component is not
found by the shim, inspect `xcodebuild -showComponent MetalToolchain -json` and the
[recorded command-local selection](docs/MONOREPO_MIGRATION.md#validation).
Do not change project deployment targets or patch kernels to fix compiler discovery.

Open [NarrationApps.xcworkspace](NarrationApps.xcworkspace), closing separately
opened app projects/packages first. Use **Libro** or **VoiceRelay** to run/archive;
**Build Both Apps** is build-only. Existing project references are configured;
there is no need to add the shared packages again. Never copy `.build`, DerivedData
or SwiftPM workspace state between checkouts.

## Signing and build products

[Libro's native guide](Libro/macos/README.md) covers its standalone build/archive
script. [VoiceRelay contributing](VoiceRelay/CONTRIBUTING.md#signed-builds) covers
its ignored local signing configuration and verified packaging script.

For routine local checks, `bash scripts/check.sh --tier release --adhoc --skip-archives`
builds both workspace configurations and audits their bundles. Omit
`--skip-archives` only when archive packaging checks are needed; release archives
are normally created manually.
Ad-hoc signing is suitable for engineering checks, not proof of Keychain,
provisioning, Developer ID/notarization or distribution behavior. Do not overwrite
an application bundle under active operator testing.

## Choose checks for the change

| Change | Start with |
| --- | --- |
| Documentation | `bash scripts/check.sh --tier quick` and the affected documentation scopes |
| Shared presentation | `bash scripts/check.sh --tier quick --scope presentation` |
| Shared narration/parser | `bash scripts/check.sh --tier quick --scope shared --filter TestName` |
| Libro workflow | `bash scripts/check.sh --tier quick --scope libro` |
| VoiceRelay workflow | `bash scripts/check.sh --tier quick --scope voicerelay --filter TestName` |
| Cross-app contracts or integration | `bash scripts/check.sh` |
| Layout, dependencies or packaging | Full fixtures and both workspace configurations with bundle audits; archive checks for distribution packaging or explicit release validation |

Run focused regressions first; broaden when changed boundaries require it.
[Development gates](docs/DEVELOPMENT.md) owns exact tier behavior, native opt-ins,
logging and exit codes. Individual app/package scripts remain supported.
[scripts/check.sh](scripts/check.sh) defaults to the full synthetic gate, not quick.
CI is an [inactive template](docs/CI.md), not an automatic acceptance claim.

Testing is **autonomous** for relevant isolated checks. GUI/Canvas, listening,
protected Safari, real Keychain/WebDAV, private-document quality, library restore
and signing-account acceptance remain in the [operator checklist](docs/OPERATOR_VALIDATION.md).
Tests must not acquire models or use the live library as setup.

## Source ownership and commits

| Owner | Responsibility |
| --- | --- |
| Root `scripts/` | Source health/setup, workspace/layout/contracts, tier orchestration/evidence |
| `swift-packages/` | Shared implementation/tests, pinned preparation/patches, codec and notices |
| `Libro/` | Intake/batch/export workflow, preferences and LibroCore tests |
| `VoiceRelay/` | Source access, queue/library, publishing, preferences and app/core tests |

Read root and relevant app/package AGENTS.md. Inspect `git status` before and after
work, preserve unrelated edits and commit coordinated changes once from the root.
The containing commit identifies all components; no app SHA pins need updating.
`health --strict-baseline` additionally requires a clean root working tree.
Each build graph retains its owned manifest and lockfile; see
[dependency maintenance](docs/DEPENDENCIES.md#maintenance-procedure-and-ownership).

Use native Swift/Apple APIs. Keep MLX helper-only, one worker per app and safe
Libro priority. Preserve original text/mappings, settings and finished audio.
Never normalize, level, limit or apply gain to audio. Keep models, credentials,
personal inputs, logs, signing material and recordings out of Git, including its
history. Use synthetic fixtures. Source publication, service/account operations
and public distribution require their applicable authorization.

Use [allowlisted formatting](docs/DEVELOPMENT.md#scoped-formatting-and-document-ownership),
not recursive formatting. Update the [current docs](docs/DOCUMENTATION.md) with
behavior changes. Dated evidence belongs in the status/migration records; preserve
historical meaning and do not turn a docs edit into a new acceptance result.
