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

## VoiceServer implementation and remaining acceptance

As of November 4, the native API, Keychain authentication, response modes,
bounded HTTP/FIFO work, Settings/private bindings and Tailscale self discovery
are wired. Both production app factories now provide coordinated scheduling;
Libro exposes explicit file-access restoration and Resume, and ownership locks
protect orphan scratch cleanup. See [current status](IMPLEMENTATION_STATUS.md)
and the [API guide](../VoiceRelay/docs/VOICESERVER.md). Full synthetic and
Debug/Release/four-audit verification passes. Remaining work is operator acceptance
of actual models, GUI/Keychain,
client playback, private-network reachability and sleep/wake; it is not another
request for model downloads or live tests by the development agent.

The following retains the dated implementation sequence and its earlier gates.

The agreed [VoiceServer implementation checklist](VOICESERVER_IMPLEMENTATION_CHECKLIST.md)
covers a native Swift private TTS endpoint using existing model/voice selection,
with per-user priority TTS API > Libro > Podcasts. Both apps share suspension,
checkpoint and recovery primitives; streaming API demand cancels unfinished
lower-priority inference and resumes it from verified checkpoints. Compatible
same-app handoffs retain resident weights. The proposed initial cross-app policy
unloads before loading in the new owner to avoid duplicate residency; shared code
alone cannot transfer live model allocations between helpers.
The design review adds a feasibility gate before broad scheduler changes,
SDK-compatible streaming defaults, speech/library ownership separation and
CLI-first Tailscale discovery. The first bounded proof uses isolated Swift clients,
fake workers and synthetic checkpoints to verify cross-process ordering, rollback
and recovery. The user authorized that proof on November 1; it is implemented
with ten focused cases. Results require helper-owned exclusion through orphan
drain/idle residency, job-plus-epoch fencing and a final atomic launch recheck.
The separately authorized next gate now implements an opt-in native helper/control
and first-unit WAV probe. All five selected adapters pass bounded same-worker
cancellation/reuse; Orpheus's measured resumed pipeline RTF is 2.05, so initial
Orpheus streaming is gated as unavailable. Complete-file operation remains planned.
The next authorized slice implements a versioned smaller live first unit, owned
incremental Qwen callback and actual two-helper reload probe. Kokoro/Chatterbox
resumed first WAV takes 0.13/0.57 s; Libro-to-VoiceRelay Kokoro/Qwen transfers take
2.75/4.09 s including reload. First-inference cancellation takes 1.45–1.65 s in
those transfers, unlike warm millisecond reuse. Qwen incremental reuse/coverage
passes at 0.19 s first WAV; the following November 2 decoder correction reduces
direct/stream PCM difference from 0.2604 to 0.00000276 and preserves identical
reset output. Raw incremental output remains probe-only pending continuity/
listening acceptance; initial Qwen streaming uses bounded complete utterances.
Initialization cancellation/EOF, loaded-weight cleanup and repeated native safety
now pass for all five adapters. The three VoiceRelay stale assertions are fixed
and full fixtures pass. Shared three-rank admission, nonblocking compatibility-lock
handoff and job/epoch commit fences are implemented and tested. An opt-in app-owned
coordinator now connects bounded preparation/generation to the shared render session,
retains its writer through suspension, and journals verified PCM for reconstruction
without inference. Seventy-three focused cases cover this seam and earlier contracts;
full fixtures, Debug/Release builds and four bundle audits pass. All five installed
adapters pass offline prepared transfer, idle API handoff/resume and owned reap
through the new coordinator, using fingerprint-matched packaged Release helpers.
The following adapter gate now binds VoiceRelay's actual final SQLite commit,
preserves the existing validation overlap and retries rejected results without a
failed row. Libro captures batch/source/destination/consent and restores verified
plans/PCM without repeating preparation. Eighty-five feature-focused cases cover
these opt-in paths. The next gate adds app-owned constructor/Quit bindings,
initialize-only setup, preview reuse and ranked host OCR/title/image admission,
including explicit context across detached source tasks. Defaults remain nil.
The following opt-in slice implements maintenance, admitted CPU/hash operations,
notification wakeups and transient waiting status. Non-seeking MP3/PCM codecs and
VoiceRelay's explicit native MP3 packaging are implemented. The November 3 full
fixture, both-configuration/four-audit and all-five-model offline gates pass, including
the correction for inherited MP3 preset attenuation. The operator accepted the
linked offline WAV/MP3 comparisons on November 3. The following slice expands
admitted document/preview/review work, separates active OCR/image/title budgets
from admission waits, and cancels/joins pending article preparation with final
snapshot revalidation. The following slice admits Libro intake/cover operations
and VoiceRelay queue-title/chunk-count preparation, rejecting stale results after
admission waits. Those legacy metadata, explicit recovery/file-access/retention
and authenticated HTTP/Settings/Tailscale paths are now integrated as described
above; their operator playback/GUI validation remains separate.
The checklist retains measurements, failed attempts and remaining native/manual
limits. Earlier stage statements about nil defaults/unwired service are historical.

Normal-serving narration now prepares with lightweight frontends and defers cold
speech weights for all five models. Libro captures a bounded CPU token-counting
limit per batch; the ordinary pipeline keeps one frontend helper across windows
and promotes it at generation. Kokoro's smaller neural pronunciation fallback
still uses inference admission and unloads before a paused handoff. The opt-in
coordinated residency path now also defers speech weights and promotes its cold
frontend in the same helper. See the
[architecture](ARCHITECTURE.md) and [L21](OPERATOR_VALIDATION.md#libro) for the
operator's Xcode build and actual-book timing gate.

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
