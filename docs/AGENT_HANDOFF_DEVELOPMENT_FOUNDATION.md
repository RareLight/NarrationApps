# Handoff prompt: NarrationApps development foundation

> Historical request, not current instructions. DF engineering is complete; the
> apps now share one monorepo and DevelopmentBaseline schema 2. Old checkout/pin,
> branch/tag and publication statements below describe October 16 only. Use
> [CONTRIBUTING.md](../CONTRIBUTING.md), [the completion crosswalk](DEVELOPMENT_FOUNDATION_CHECKLIST.md)
> and [the current roadmap](IMPLEMENTATION_PLAN.md). Do not execute this prompt
> again or restore the old repository layout.

Original implementation request, retained as provenance. Current completion,
evidence and external blockers are owned by
[the checklist](DEVELOPMENT_FOUNDATION_CHECKLIST.md) and
[status](IMPLEMENTATION_STATUS.md); do not restart completed stages from this prompt.

Implement the remaining stages in
`/path/to/NarrationApps/docs/DEVELOPMENT_FOUNDATION_CHECKLIST.md`.
Read the complete checklist, then proceed through DF1–DF8, developing, testing and
iterating until you need actual operator validation or externally controlled access.
DF0 (the coordinated Git checkpoint) is already complete. Do not redo the migration.

Start in `/path/to/NarrationApps`. Read its AGENTS.md and the
app/package instructions, README.md, DevelopmentBaseline.json, docs/README.md,
docs/ARCHITECTURE.md, docs/IMPLEMENTATION_STATUS.md and docs/IMPLEMENTATION_PLAN.md.
Inspect relevant source/scripts/tests before editing. This prompt supplies the
implementation request; don't stop at proposing another plan.

The layout is:

```text
NarrationApps/                   # root/shared Git repository, main
  NarrationApps.xcworkspace/
  DevelopmentBaseline.json
  docs/  scripts/
  swift-packages/                # SwiftNarration; no nested .git
    Package.swift
    AppPresentation/             # independent Swift package
  Libro/                        # ignored independent Git repo, unification
  VoiceRelay/                   # ignored independent Git repo, unification
```

The shared/native code checkpoint is root `7aa4740`; a subsequent root documentation
commit includes this prompt. The local annotated tag
`native-unification-2026-10-16` identifies the coordinated checkpoint in all three
repositories; preserve it. Libro is `3641eaf5fad8a87cb162808c66b25761614b76a0` and
VoiceRelay is `681b8f6b09cecea870acdf472b2ee9b74840248b`. Check the actual manifest,
Git statuses and newer commits before proceeding; preserve any subsequent operator
work. Do not reset, checkout, stash or overwrite a changed repository to force the
baseline. The old standalone folders outside NarrationApps are archival material,
not active sources. The root remote is unconfigured; app origins are recorded in
the manifest. All checkpoint commits are local, with no remote backup/publication
claimed. Do not create a new chat or message another chat; the operator is starting
this implementation chat directly.

The operator confirmed both apps build and run on October 16, 2026. Basic
build/launch smoke is accepted. Full feature/listening/OCR/private-document,
protected Safari, Keychain, WebDAV, podcast/player, restore and distribution
acceptance is not implied. docs/OPERATOR_VALIDATION.md is the single manual list.

Prior automated gates passed with Xcode 27.1 (27A9275), Swift 6.4, macOS 27.0 SDK,
arm64: shared 229 XCTest (three opt-in skips), one shared Swift Testing, two
AppPresentation, 18 LibroCore, 303 VoiceRelay core and 141 app cases. Both Debug and
Release workspace builds, four ad-hoc signatures/Metal probes and Kokoro/Soprano
through each Release helper passed. Ignored evidence is at
`.local/migration/root-layout/`; it may be absent on another checkout. Don't rerun
expensive gates merely to restate this baseline; choose checks appropriate to changes.

The implementation priorities are:

1. Root contributor guidance, safe native setup/health diagnostics and manifest use.
2. Fast/full/native/release tiers and reliable evidence; preserve existing checks.
3. CI-ready configurations using those entry points; external activation separate.
4. Canonical synthetic fixtures and architecture/audio/persistence regression gates.
5. Small behavior-preserving decompositions of the large app files.
6. Consistent scoped formatting, documentation ownership and stale-record cleanup.
7. Dependency/patch/lock/release-maintenance procedures and final verified handoff.

Critical constraints:

- Keep product/runtime native Swift/Apple APIs with existing pinned native FOSS.
  No Python, external FFmpeg/ffprobe, product CLI or additional speech engine.
  Thin existing shell build launchers are fine; use Swift for structured tooling.
- MLX stays in the private helpers. One worker per app; Libro has interactive
  priority and VoiceRelay yields at safe boundaries. Preserve cancellation/join,
  memory safeguards, ordered generation and compatibility identifiers.
- No normalization, volume leveling, gain, limiting or dynamics compression.
  Preserve exact Float32 WAV behavior, the podcast AAC 64 kbps/24 kHz profile,
  accepted speech policy, source prose/provenance, dictionary and saved preferences.
- Preserve private models/data, finished/published audio, credentials, artwork
  masters and original dependency notices. No implicit model downloads, live
  service activity, GUI operation or destructive cache/library resets.
- Keep app code/history in its own ignored repository. Don't replace this layout
  with submodules, merge histories, add a root package manifest or copy shared code.
- Prefer existing Apple/Swift tools and minimal complete changes. Don't introduce
  speculative libraries, broad lifecycle rewrites, arbitrary dependency upgrades,
  timeout increases or mass formatting mixed with behavior changes.
- Continue independent stages after focused gates pass. Serialize heavy GPU work;
  don't overlap deadline-sensitive tests with heavyweight builds. Mark unavailable
  native/remote gates honestly and continue unaffected local work.
- Do not push, configure new remotes, create external CI resources, incur costs,
  operate signing accounts or publish without direct human authorization. Prepare
  local configs and explicit activation instructions if those steps are unavailable.

Use `bash scripts/check.sh` from the root for current full isolated fixtures and
layout/docs/packaging checks. Individual package/app scripts remain available.
Build through the root workspace and its existing app schemes; Build Both Apps is
build-only, not an Archive/Test scheme. Keep normal signing configuration intact;
ad-hoc command-line overrides establish engineering evidence only. VoiceRelay
project-file edits require its unique-source-reference regression and an Xcode build.

Make logical commits in each owning repository as stages pass. After validated
app commits, update the compatible app revisions in DevelopmentBaseline.json in a
root commit; never embed a root self-SHA circularly. Keep the detailed checklist
and current status accurate. At handoff, report what changed, exact checks/results,
remaining external activation and the specific operator validation still needed.
