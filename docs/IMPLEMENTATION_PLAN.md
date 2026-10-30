# Current implementation and remaining work

Reviewed October 28, 2026. This roadmap separates implemented behavior, remaining
acceptance and research proposals. Detailed technical contracts live in
[architecture](ARCHITECTURE.md); engineering evidence lives in
[current status](IMPLEMENTATION_STATUS.md). Historical stage plans do not schedule
new work by themselves.

## Implemented baseline

One monorepo contains Libro, VoiceRelay, SwiftNarration, AppPresentation and the
combined Xcode workspace. Both apps share semantic document intake, pronunciation,
native speech preparation, supervised helpers, audio handling and common Settings.
Libro owns batches/exports; VoiceRelay owns Reading List discovery, durable queues,
WebDAV publishing, backup and recovery.

Current features include:

- Shared fresh-start speech setup in NarrationUI, using VoiceRelay's layout and
  download/cancel/defer actions in both apps, with app-owned lifecycle and options.
  See [Settings ownership](SETTINGS_ALIGNMENT.md) and the L01/V01 operator checks.

- Shared Qwen3-TTS 1.7B CustomVoice, Chatterbox Turbo and Orpheus adapters,
  complete preset coverage, immutable optional reference voices, model-aware setup
  and captured selections. See the [integration record](MULTI_MODEL_TTS_IMPLEMENTATION_PLAN.md)
  for engineering evidence and remaining operator acceptance.

- Text/Markdown/RTF/PDF and DRM-free EPUB intake, bounded OCR/image descriptions,
  authored navigation, source mappings and legacy text encodings.
- Libro Start/Pause/Resume/Skip/Stop, queue reordering, progressive PDF previews,
  automatic cover thumbnails, manual cover choices, saved speech settings, owned
  cancellable imports and source-safe existing-output review.
- Shared footnote/auxiliary choices, off-by-default citation stripping and
  experimental dictionary-constrained PDF word joining; conservative margin,
  column and typography cleanup; simple scientific text/table narration.
- Shared pronunciation editing/live previews and 47 bundled voice samples and shared model speed/quality guidance.
- VoiceRelay automatic discovery/generation/publishing, Sync Now, Uploads and Server
  Audio, bounded reconciliation, background-safe credentials, default show art and
  default-on login startup for fresh configurations, controlled only in General Settings.
- Default-on timed WebVTT transcripts for newly queued VoiceRelay articles,
  verified sidecar upload and standard RSS transcript references; segment timing
  and player-specific acceptance are separate from word-level alignment.
- Explicit pinned source setup, tiered checks, evidence summaries, scoped formatting
  and an inactive CI template.
- A standalone Swift model/voice benchmark with explicit model preparation,
  isolated inference, performance reports and a resumable listening bracket.

New Kokoro settings use Heart at 1.0× with the accepted pacing profile. Delivery A
spoken-form listening, including capital-A labels, is accepted. Soprano keeps its
native frontend. One worker per app, helper-only MLX, safe Libro priority,
source/finished-recording preservation and unchanged audio levels remain invariants.

## Remaining operator acceptance

October 30 long-form preparation work is detailed in the authorized
[quality implementation plan](LONGFORM_QUALITY_IMPLEMENTATION_PLAN.md). Its
Kokoro semantic activation is approved and implemented; other models retain their
optional experiment. Compound-flow retesting, broader paired listening and review
controls require B09. Contextual homograph inference and automatic
repair/emotion remain deferred, not implicitly enabled by the new lexicon.

Use the [single checklist](OPERATOR_VALIDATION.md) to record results. Unreported
cases remain open; successful builds or document planning do not mark them passed.

| Area | Remaining acceptance |
| --- | --- |
| Libro UI, queue, settings and lifecycle | Relevant L01–L20 interactions, larger text, output dialogs and cancellation |
| Original document freeze and quality | L06/L08/L10 plus private-document OCR/layout/caption review |
| Covers, navigation and captured choices | L17–L19 and V17–V19; real exported-player/feed behavior |
| Progressive previews | L20; actual-document latency, scrolling, completion and close/reopen behavior |
| PDF flow, word joins and scientific text | B06–B08; source comparison and matched listening |
| Cross-app operation | Shared dictionary edits, worker priority, waiting/cancellation and playback |
| VoiceRelay services and recovery | Protected Safari, normal-signed Keychain, WebDAV/readback, podcast playback and disposable-library restore |
| Installation/distribution | D01/D02 only when a clean test environment or release route is available |
| Narrator model selection | M01; blind local-web bracket, then held-out and long-form finalist listening |

Resolve reported acceptance failures in the owning shared package or app, add
focused regressions and repeat affected gates. Do not change defaults merely to
make a difficult document pass. Preserve previous operator builds and actual data.

## Proposed research and release work

These are candidates requiring an explicit scope decision, not unfinished steps
of an already completed implementation:

- Context-sensitive homographs and broader written-to-spoken forms; see
  [normalization research](TEXT_NORMALIZATION_RESEARCH.md).
- Better scientific structure/MathML, region-based review and advanced mathematical
  speech; see [academic PDF evaluation](ACADEMIC_PDF_EVALUATION.md). Current prose
  insets and the single complex-equation reference notice are already implemented.
- Unsupported complex/rotated layouts, chaptered audio exports and broader
  annotation scheduling. Current authored Contents navigation is implemented.
- CI provider/action review, runner setup and explicit activation. Source
  publication does not activate the [CI template](CI.md).
- Signed public app distribution and independent package/registry releases. Local
  prepared dependency paths still require a release-ready strategy for remote
  package consumers; see [package boundaries](PACKAGE_BOUNDARIES.md).

Routine checks must not reset preferences/libraries, fetch old snapshots,
regenerate published recordings, install models, launch the GUI, operate accounts
or contact live product services. The current task's authorization determines
which proposed work, if any, proceeds.
