# Contributing to NarrationApps

One Git repository owns the workspace, `docs/`, `scripts/`, `swift-packages/`,
`Libro/` and `VoiceRelay/`. Shared fixes and tests belong in the packages;
app-specific workflows remain in their app directories.
AppPresentation is an independent zero-dependency package. Start with
[architecture](docs/ARCHITECTURE.md), [current status](docs/IMPLEMENTATION_STATUS.md)
and the relevant [Libro](Libro/AGENTS.md), [VoiceRelay](VoiceRelay/CONTRIBUTING.md)
or [package](swift-packages/AGENTS.md) instructions.

## Setup

Clone `git@github.com:RareLight/NarrationApps.git` once; both apps are included.
Private preferences, credentials, documents and models are excluded.
`DevelopmentBaseline.json` validates component paths and records the tested toolchain;
its containing commit identifies the entire source composition.

- `bash scripts/develop.sh health`: offline, read-only checkout/tool readiness.
- `bash scripts/develop.sh health --strict-baseline`: additionally require a clean
  monorepo working tree. App sources must be tracked by root with no nested Git metadata.
- `bash scripts/develop.sh setup --prepare-dependencies`: explicit pinned source
  preparation, patches and LAME; may use network. Never installs speech models.
- `bash scripts/develop.sh setup --resolve`: existing workspace preparation/
  resolution plus locked shared/LibroCore/VoiceRelay fixture-graph acquisition.
  Review lockfile diffs. `--clone-apps` is retired because app sources are included.

Use native arm64 Xcode/Swift with an SDK supporting the manifest deployment target.
The manifest records a tested toolchain, not a claim about other SDKs. Open only
`NarrationApps.xcworkspace` for concurrent app development. See
[package/workspace setup](docs/PACKAGE_BOUNDARIES.md).
Do not copy `.build`, DerivedData or SwiftPM workspace state between checkouts.

## Checks and ownership

`bash scripts/check.sh` remains the full isolated fixture gate. Individual shared
and app scripts remain supported. Choose quick/full/native/release via
[development gates](docs/DEVELOPMENT.md); see [CI activation](docs/CI.md) and
[canonical regression ownership](docs/REGRESSION_CORPUS.md).
Source/model preparation, GUI, protected Safari,
Keychain, network services and signing accounts are not implicit test setup.
Testing mode is **autonomous**, confirmed October 17, 2026 in the root/shared/Libro
instructions. Run relevant isolated checks automatically, preserving the operator's
current test bundle and the manual ownership of GUI/listening/protected/live gates.

| Operation | Maintained owner |
| --- | --- |
| Manifest health, explicit setup, cross-app validation | Root `scripts/` |
| Pinned sources/patches, codec, shared fixtures | `swift-packages/scripts/` |
| LibroCore fixtures, project/plist checks | `Libro/macos/scripts/check.sh` |
| VoiceRelay core/app tests | `VoiceRelay/Package.swift` |
| Fake atomic packaging, app docs | `VoiceRelay/scripts/` |
| GUI, listening, private inputs, services, distribution | [Operator checklist](docs/OPERATOR_VALIDATION.md) |

Inspect root `git status` before and after work. Commit coordinated changes once
from the root. App directories inherit that same Git history; no app revision pins
need updating. Keep package manifests/lockfiles separately owned by their build
graphs. See [migration provenance](docs/MONOREPO_MIGRATION.md) for original history
recovery. Publication and signing-account operations remain explicit actions.

Use synthetic isolated fixtures. Never commit private prose, URLs, model files,
settings, credentials, recordings or backups. Preserve completed/published audio.
MLX stays helper-only, one worker per app, with safe Libro priority. No gain,
normalization, leveling, limiting or compression. Build/test evidence is not
feature, acoustic, Keychain or distribution acceptance.

For pin/patch updates, separately owned resolution files, compatibility versions
and generated release evidence, follow
[dependency maintenance](docs/DEPENDENCIES.md#maintenance-procedure-and-ownership).
