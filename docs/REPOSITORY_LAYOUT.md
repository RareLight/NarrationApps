# NarrationApps repository layout

The active root is `/path/to/NarrationApps`:

```text
NarrationApps/                    # shared/project Git repository (main)
  .git/
  AGENTS.md
  README.md
  docs/
  scripts/                       # project checks, workspace resolution, packaging support
  NarrationApps.xcworkspace/
  swift-packages/                 # package directory, no nested .git
    Package.swift                # SwiftNarration
    AppPresentation/              # independent Swift package
    Sources/  Tests/
    scripts/                     # package checks/preparation/sample regeneration
    Patches/  DependencyTests/  ThirdPartyNotices/
  Libro/                         # independent app repository (unification)
    .git/
  VoiceRelay/                    # independent app repository (unification)
    .git/
```

The original shared repository's `.git`, history and pending edits were promoted
to the root, with package-file path moves recorded in its index. Pending content
edits remain preserved. The empty experimental root repository was discarded at
the user's request. Root `.gitignore` excludes `/Libro/` and `/VoiceRelay/`; each
app retains its own Git history, settings and workflows. Use Git from the root for
shared/project changes and from the app directory for app changes.

`swift-packages` retains its name to preserve SwiftPM identity. There is no root
Package.swift and no copied package source in either app. Local package dependency
paths are unchanged by the Libro folder rename because directory depth is unchanged.
Shared documentation and project support live at the root; package-specific native
preparation, regression fixtures and source tools stay with their packages.

Open `NarrationApps.xcworkspace` after closing old project/package windows. Libro
and VoiceRelay schemes run/profile/archive each app. Build Both Apps compiles both
with Debug or Release; it is not an archive scheme. Individual projects can still
build against the sibling package directory without the other app's checkout.
See [workspace details](PACKAGE_BOUNDARIES.md).

## Root-layout validation

The app directory inside NarrationApps was renamed to `Libro`; maintained
source, test, workspace/scheme, script and documentation references were updated.
The sample generator's default model-workspace lookup now uses `Libro`. Cross-app
resolution, document checking and packaging support scripts moved to root `scripts/`.
Run `bash scripts/check.sh` from the root for layout, docs, shared/Libro fixtures,
VoiceRelay fixtures and isolated packaging tests. Package-only checks remain
`bash swift-packages/scripts/check.sh`.

Final root-layout validation passed on October 16, 2026:

- Root layout/docs checks and the complete shared/Libro gate: 229 shared XCTest
  cases (three existing opt-in skips), one Swift Testing case, two AppPresentation
  cases and 18 LibroCore cases. VoiceRelay: 303 core and 141 app cases. Isolated
  build/copy/sign-failure and atomic packaging checks also passed.
- Fresh combined arm64 Debug and Release builds; deep/strict ad-hoc verification
  of all four apps and Metal-ready probes from all four packaged helpers.
- Both Release helpers generated Kokoro and Soprano speech under a sandbox denying
  network access, original repositories, the old app path and previous workspace
  build products. Libro's bundled MP3 encoder and VoiceRelay WAV output passed
  complete finite/nonzero mono decoding with ordered chunks and one worker.
- No active old app/workspace references, broken model links or maintained Python
  files. Root Git ignores both app repositories, owns no app source, and preserves
  all prior repository HEADs/refs and staged content across the package path moves.

Private reports/logs are in root `.local/migration/root-layout/`. Earlier copy-stage
reports are in `.local/migration/copy-stage/`. Obsolete workspace DerivedData was
removed from `swift-packages/.build/`; current workspace builds use root
`.build/WorkspaceDerivedData/`, while SwiftPM package builds retain their own caches.
LibroCore's generated scratch was recreated after the rename; its fresh 18-test
run passes without old-path warnings. GUI, listening and account acceptance remain
operator-owned.

## Source, assets and cleanup

Migration copied the repositories, not their generated SwiftPM/Xcode state.
Every retained file was checksum-compared before relocation edits; Git HEADs,
refs, staged/unstaged changes and untracked source lists matched each original.
Original directories outside NarrationApps were not deleted or edited.

Fresh pinned dependency preparation regenerates local native sources and MP3
codec output. Builds regenerate DerivedData, module/manifest caches and Metal
resources. No copied `.build`, package workspace state or compiled app is needed.
Native validation model assets are kept privately under `swift-packages/.local/validation-workspace`.
This directory and migration evidence are ignored by Git.

The new working trees omit Python environments/runtimes/caches, portable CLI
bundles, obsolete historical plans/handoffs and HTML design exports, legacy
PyTorch voice files/Hugging Face cache, retired CLI installer/Python version
marker/legacy model records, old generated fixture state and duplicate
compiled icon previews/exports. Current native Swift tests, authored icon/vector
sources, native model assets, copyright/license notices and dependency patches
are retained. Historical source remains in the independent Git histories and
original directories. Native FOSS dependency checkouts may contain upstream
non-Swift tooling; the apps and maintained tools have no Python runtime dependency.
Compatibility readers for existing metadata/library records remain to preserve
published audio and user state.

## Migration validation and archival gate

Automated migration validation passed from the new root on October 16, 2026:

- Fresh pinned dependency preparation; no copied build state.
- Required shared/Libro gate: 229 shared XCTest cases (three existing opt-in skips),
  one shared Swift Testing case, two AppPresentation cases and 18 LibroCore cases.
- VoiceRelay: 303 core and 141 app cases.
- Combined arm64 Debug and Release builds; all four ad-hoc app signatures and
  embedded Metal helper probes.
- Each Release helper generated Kokoro and Soprano synthetic speech with network
  access and reads from all three original repositories denied. Libro's embedded
  MP3 encoder and VoiceRelay's WAV output decoded completely as finite, nonzero,
  mono audio at the model's native rate, with one worker and ordered chunks.
- No maintained Python source/configuration, old absolute source paths, dangling
  retained symlinks or links back to the originals. Independent Git histories,
  refs and pre-existing working changes were preserved before migration edits.
- Final checksums and Git checks confirm the original repositories are unchanged.

Private reports, logs and synthetic recordings are retained in
`.local/migration/copy-stage/`; they are ignored by Git. The native harness JSON's `offline`
field reflects its optional command-line flag only; these runs instead used the
outer `deny-originals.sb` sandbox, which enforces both network and original-folder
restrictions. Its denied-read control check passed.

A read-only preference audit found both apps' currently selected model roots and
Libro's output folder outside the original repositories. Those settings and
external data were left unchanged. Original folders retain legacy/private material
omitted from the new development copies; archive them rather than discarding that
material if it might still be needed.

The operator confirmed on October 16, 2026 that both apps build and run from the
new layout. That accepts the basic build/launch smoke gate; it does not substitute
for specific model, playback, library or account acceptance.

Before archiving the originals:

1. Close old project/package windows and open the workspace in this new parent.
   Confirm both schemes load and run each new app; check existing model selection,
   voice sample playback and library/output settings. This final GUI smoke test is
   operator-owned. Use normal team signing for VoiceRelay Keychain/server checks;
   ad-hoc validation does not establish live account acceptance.
2. Update Codex's project folders to NarrationApps, Libro and VoiceRelay. This chat
   still starts in the original Libro folder; do not continue development there.
3. After that smoke test, the old sibling folders outside NarrationApps can be
   archived. No active source/build/model dependency on those folders was found.

The parent README, workspace, cross-app documentation and package sources now
share the promoted root Git repository. No originals were removed,
no settings/Keychain data were migrated. The coordinated baseline is recorded in
[DevelopmentBaseline.json](../DevelopmentBaseline.json); publication remains separate.
