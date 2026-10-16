# Contributing to NarrationApps

Root owns the workspace, `docs/`, `scripts/` and `swift-packages/`. Libro and
VoiceRelay are ignored, independent repositories, not submodules. Shared fixes
and tests belong in the packages; app workflows/history stay in their owners.
AppPresentation is an independent zero-dependency package. Start with
[architecture](docs/ARCHITECTURE.md), [current status](docs/IMPLEMENTATION_STATUS.md)
and the relevant [Libro](Libro/AGENTS.md), [VoiceRelay](VoiceRelay/CONTRIBUTING.md)
or [package](swift-packages/AGENTS.md) instructions.

## Setup

Root cloning does not include either app, private preferences, credentials or
models. `DevelopmentBaseline.json` is the Codable-validated compatible composition;
its containing Git commit identifies root. Branch names are informational.
The coordinated local tag is immutable. These checkpoint commits are local;
remote availability has not been established. No root remote is configured.

- `bash scripts/develop.sh health`: offline, read-only checkout/tool readiness.
- `bash scripts/develop.sh health --strict-baseline`: additionally require clean,
  exact recorded app commits. Development divergence normally produces warnings.
- `bash scripts/develop.sh setup --clone-apps`: explicitly authorized network
  source acquisition into absent app paths only, detached at manifest commits.
  Unavailable remote commits fail without occupying the app path. Existing folders
  are preserved, never fetched/reset/stashed/checked out.
- `bash scripts/develop.sh setup --prepare-dependencies`: explicit pinned source
  preparation, patches and LAME; may use network. Never installs speech models.
- `bash scripts/develop.sh setup --resolve`: preparation plus locked workspace
  resolution. Review lockfile diffs. Do not promise a fresh clone works until
  owners publish the required commits and root.

Use native arm64 Xcode/Swift with an SDK supporting the manifest deployment target.
The manifest records a tested toolchain, not a claim about other SDKs. Open only
`NarrationApps.xcworkspace` for concurrent app development. See
[package/workspace setup](docs/PACKAGE_BOUNDARIES.md).
Do not copy `.build`, DerivedData or SwiftPM workspace state between checkouts.

## Checks and ownership

`bash scripts/check.sh` remains the full isolated fixture gate. Individual shared
and app scripts remain supported. Source/model preparation, GUI, protected Safari,
Keychain, network services and signing accounts are not implicit test setup.
The explicit foundation implementation request authorizes automated local checks
for that session; otherwise follow the recorded app testing mode and confirm an
unset mode before routine validation.

| Operation | Maintained owner |
| --- | --- |
| Manifest health, explicit setup, cross-app validation | Root `scripts/` |
| Pinned sources/patches, codec, shared fixtures | `swift-packages/scripts/` |
| LibroCore fixtures, project/plist checks | `Libro/macos/scripts/check.sh` |
| VoiceRelay core/app tests | `VoiceRelay/Package.swift` |
| Fake atomic packaging, app docs | `VoiceRelay/scripts/` |
| GUI, listening, private inputs, services, distribution | [Operator checklist](docs/OPERATOR_VALIDATION.md) |

Inspect all three statuses before and after work. Make focused commits in each
owner; after validated app commits update their full SHAs in the root manifest
and commit root. Never embed root's own SHA in itself. Do not rewrite checkpoint
tags, publish, configure remotes or change signing settings without authorization.

Use synthetic isolated fixtures. Never commit private prose, URLs, model files,
settings, credentials, recordings or backups. Preserve completed/published audio.
MLX stays helper-only, one worker per app, with safe Libro priority. No gain,
normalization, leveling, limiting or compression. Build/test evidence is not
feature, acoustic, Keychain or distribution acceptance.
