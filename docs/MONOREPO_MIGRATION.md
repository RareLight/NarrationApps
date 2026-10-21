# Monorepo migration — October 20, 2026

NarrationApps now owns `Libro/`, `VoiceRelay/`, `swift-packages/`, the workspace,
documentation and project scripts in one Git history on `main`. Clone the root
once; app submodules and separate app checkout pins are not used. The SwiftPM
packages and per-build-graph lockfiles retain their existing paths and ownership.

The origin is `git@github.com:RareLight/NarrationApps.git`. No push is performed by
this migration; the operator will publish manually after reviewing the repository.

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

Migration validation results are recorded here after execution. Automated gates
use synthetic isolated inputs; GUI, listening, protected files, live services and
signing accounts remain operator-owned. Operator test bundles are preserved.
