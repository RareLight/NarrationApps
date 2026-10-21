# Monorepo migration — October 20, 2026

NarrationApps now owns `Libro/`, `VoiceRelay/`, `swift-packages/`, the workspace,
documentation and project scripts in one Git history on `main`. Clone the root
once; app submodules and separate app checkout pins are not used. The SwiftPM
packages and per-build-graph lockfiles retain their existing paths and ownership.

The origin is `git@github.com:RareLight/NarrationApps.git`. No push is performed by
this migration; the operator will publish manually after reviewing the repository.
The existing GitHub starter commit `fe3e2423f35268167ac9ae2a5c10458aba524ed4`
is retained as an ancestor. Its AGPL license agrees with the project license;
its additional generated-output exclusions and speech-library credit are retained.
The local branch can therefore be published with a normal `git push -u origin main`.

## Imported history and privacy

Original source tips:

| Source | Original branch | Original tip |
| --- | --- | --- |
| Root/shared | main | `82b7c9fa188569c40bc5aa490cf210934194da2c` |
| Libro | unification | `522b83cc4f9bc888bae93978ee71f1ae078621ae` |
| VoiceRelay | unification | `7c8036fa79fc9c2ff24918851834b5d908fb3d58` |

Fresh isolated local clones were filtered with upstream
[git-filter-repo](https://github.com/newren/git-filter-repo) at
`d7b75aca907380f608892cc289e616f195427b99`, then merged with app paths prefixed.
Imported commit IDs change because of path prefixes and privacy filtering; authors,
messages and source ancestry remain represented. Old independent refs/tags are
retained only in local recovery copies, avoiding unsanitized publication refs.

The import excludes obsolete validation/design records, historical document
excerpts, local signing configuration, generated icon exports/previews and personal
home paths. The old root status log is replaced by a source-focused current status;
input-specific private results remain local. No model weights or personal input
PDF/EPUB/audio files are included. Maintained synthetic fixtures, authored product
artwork, the bundled synthetic voice samples, patches and original licenses remain.
Root ignores cover private inputs, model weights, credentials, caches, library
state, recordings, archives and per-user configuration. Ignore rules do not replace
review of deliberately forced additions.

## Local recovery

Ignored `.local/monorepo-migration/` contains the original `root.git`, `Libro.git`
and `VoiceRelay.git` directories under `original-git/`, import commit maps,
privacy inventories and local validation evidence. These are private backups;
never publish that directory or force-add its contents. Existing ignored app data,
model assets and build caches remain in place. Original sibling checkouts outside
NarrationApps are unchanged. Restoring the old metadata would restore the former
three-repository layout; preserve any newer monorepo work before doing so.

## Validation

The full isolated gate passes at source commit
`db2ad570fce7a72ee0ce528fc9439308521394ac`, with a clean source tree:
`.local/validation/full-4CD31DAF-DDD8-4CF8-B94F-4F70819C4758/summary.json`.
This includes the updated development tooling regressions (78 assertions), layout,
documentation, shared/app fixtures, pinned preparation and isolated packaging tests.
Existing opt-in skips remain skips rather than acoustic or private-document passes.

Both apps pass fresh combined arm64 **Debug and Release** workspace builds in
`.build/MonorepoValidation/`, plus all four full bundle audits: ad-hoc signatures,
helper-only MLX, resources/notices/samples and offline packaged Metal probes.
The Libro audits also verify its bundled codec. Logs and bundle reports are in
`.local/monorepo-migration/`; existing operator builds are preserved.

This host initially reported a missing Metal compiler through Xcode's default shim.
The component installer confirmed installed Metal Toolchain `27A266a`. Fixture
validation used the installed toolchain's explicit `TOOLCHAINS` path; workspace
builds used `-toolchain com.apple.dt.toolchain.Metal.32023.921.5`, verified in effective
build settings. These are command-local selections, with no project/signing changes.
`xcodebuild -showComponent MetalToolchain -json` reports the current local identifier
and search path for reproducing that selection.

A fresh source-only local clone passes layout and documentation checks without
separate app acquisition. All **466 checked product/source/resource files** match
the original tips. The complete imported history passes Gitleaks 8.30.1 with no
findings, plus path/home-directory/private-identity/model/large-blob checks.
The largest reachable blob is the intended podcast cover image (1,078,151 bytes).
Thirteen representative private/generated paths pass ignore checks; the tracked
tree contains no Git links, symlinks, caches or private migration storage.
Git object integrity checks pass. Detailed inventories and import maps remain local.

No speech models, real credentials or personal documents were used in validation.
GUI, listening, protected files, live services and signing accounts remain
operator-owned. No application was installed or launched, and no push was performed.
