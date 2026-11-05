# Current implementation status

Current-state documentation updated November 4, 2026. Feature-specific engineering
evidence is dated below. NarrationApps is one repository containing Libro,
VoiceRelay, SwiftNarration, AppPresentation and the combined Xcode workspace.
The containing commit identifies all maintained source. See
[monorepo migration](MONOREPO_MIGRATION.md), [architecture](ARCHITECTURE.md),
[remaining work](IMPLEMENTATION_PLAN.md) and [operator validation](OPERATOR_VALIDATION.md).
Private document reviews and their input-specific results are retained locally;
they are excluded from the publication history. Synthetic fixtures remain maintained.

## VoiceServer API and production coordination — November 4, 2026

VoiceRelay now owns a disabled-by-default native HTTP/1.1 service with authenticated
`/v1/models`, `/v1/audio/voices` and `/v1/audio/speech` routes. Its request subset
captures existing speech/narration/pronunciation settings, defaults MP3/PCM to
binary streaming and returns complete MP3/WAV/PCM when requested. Orpheus remains
complete-file only; raw incremental Qwen remains probe-only. Strict schema,
connection/body/input/queue/output limits and receipt/queue/request/write deadlines
bound accepted work. Errors are sanitized and never appended to active audio.

VoiceServer Settings owns explicit private address choice, Keychain bearer key
generation/copy/rotation, self-only Tailscale CLI discovery, status and joined
listener Stop/sleep/Quit cleanup. Interface changes never select a replacement
LAN address. Keys/request text do not enter defaults, logs or podcast persistence.
Listener-running and model readiness remain distinct. See the
[API guide](../VoiceRelay/docs/VOICESERVER.md) for the supported client contract.

Production factories in both apps now supply the shared coordinator. Preparation
can initialize a cold frontend without speech weights and promote the same helper;
compatible live demand can take over promotion before lower-priority speech.
Versioned directory locks protect scratch until host/helper writers are joined;
cleanup retains unknown or still-owned work. Private coordinated wire is 7;
ordinary production speech IPC remains 4. Native worker stderr is discarded.

Libro Interrupted Batches restores original file access, validates captured
settings/source/destination proofs and requires a separate Resume. Verified
completed outputs are excluded; interrupted records remain until resumed or
explicitly discarded. Verified-complete records are cleaned after joined work;
damaged/unavailable records remain. Legacy VoiceRelay snapshot-derived display
metadata and saved previews now use admitted CPU reads outside mutation ownership.

The new API fixtures cover contract/authentication/Keychain seams, HTTP parsing and
routing, FIFO/overload, discovery, slow-write timeout/cancellation and native-renderer
response cleanup using the synthetic helper. All 13 API fixtures pass, as do cold
frontend/promotion, scratch and batch recovery cases. The full fixture gate passes,
including all 383 VoiceRelay core and 185 app cases. Debug/Release workspace builds
and all four bundle audits pass. The broader run found a cancelled-task checkpoint
on raw mutation metadata that could prevent a Running row from settling to Paused;
the checkpoint now applies only to admitted display reads. Origin fallback remains
read-only, and the existing cancellation/shutdown regressions pass. Settings fixtures
now include the sixth pane, and the renderer fixture finds the prepared codec under
the full gate as well as focused runs.

Evidence is indexed in `.local/validation/voiceserver-api-20261104/gate-result.json`.
The full gate is `full-89690433-8A7A-4A1E-ABAE-6C62550ECFFD`; build/audit evidence
is `release-39234881-C4E3-483F-ABF1-CA62A4BFB95A`. Build products remain intermediate
engineering output in `.build/WorkspaceDerivedData`; operator candidates were not
replaced. No archive, commit or push was performed.

These are engineering checks, not actual-model,
GUI, signed Keychain, listening or live-network acceptance; those remain under
[VS02–VS03](OPERATOR_VALIDATION.md#voiceserver-staged-acceptance). No listener,
real model or private document was exercised for these fixtures.

## VoiceServer intake, artwork and queue metadata — November 3, 2026

Opt-in CPU admission now covers Libro's input discovery, automatic/manual cover
selection, retained-cover snapshots and unused-cover cleanup. Filesystem entries,
cover-document reads and image operations have cooperative checkpoints. An
already-issued File Provider, PDF-rendering or ImageIO call finishes cooperatively;
there is no claim of immediate cancellation inside those native calls.

VoiceRelay's queued-title preparation and chunk-count planning run through the
same CPU executor. A title edit releases database ownership before waiting and
rechecks the exact saved row, snapshot and episode before its transaction can
commit. Queue plans revalidate both successes and verification failures after
actor reentry; a changed or removed row is neither started nor marked failed
from stale evidence. Source bytes and completed recordings remain unchanged.

All 49 focused cases pass, covering intake suspension/resume, cancellation before
cover access, preserved cover assets, title-edit conflicts and stale queue plans.
All 369 VoiceRelay core and 185 app cases also pass. The final full fixture gate,
both ad-hoc Debug/Release workspace builds and all four bundle audits pass;
explicit native/private opt-ins retain their skips. The broader run exposed stale
setup-inventory and removal-join fixtures, which now exercise their intended paths.
No production setup behavior was changed.

Evidence is indexed in
`.local/validation/voiceserver-intake-metadata-20261103/gate-result.json`.
The final full and build gates are `full-8FEE7799-C4DD-4271-A51B-848B9F5FFB73`
and `release-75EB42CB-A3D1-427D-9EDF-B04A64EE6315`. Build products in
`.build/WorkspaceDerivedData` remain intermediate engineering output, separate
from operator candidates. No GUI app was launched, no real voice model or private
document was run, and no archive, commit or push was performed. GUI compatibility
remains operator-owned under [VS01b](OPERATOR_VALIDATION.md#voiceserver-staged-acceptance),
using normally signed Xcode builds of the Libro and VoiceRelay schemes.

Default constructors still supply nil. Legacy metadata reads, cold coordinated
frontend residency, explicit recovery/file-access UI, retention/repair and the
HTTP/credentials/Settings/Tailscale paths remain activation work.

## Deferred speech models and CPU text preparation — November 3, 2026

Normal-serving narration now starts with lightweight frontends for all five
models, deferring speech weights until generation and promoting the same helper.
Qwen, Chatterbox and Orpheus use their existing local tokenizers; Soprano uses its
text budget. Kokoro still serializes its smaller neural pronunciation fallback
under inference admission and unloads it when preparation pauses or yields.
Large speech models retain their existing per-utterance reap boundaries.

Libro General → Text preparation adds Maximum CPU workers. Automatic uses
available cores, capped at 32; a captured manual maximum is capped at available
cores. Bounded concurrent tokenizer counts preserve the original serial phrasing,
source mappings and acoustic identity. Recovery captures the limit; old manifests
restore serial behavior. Speech generation stays in the MLX helper.

The full fixture gate passes, including 169 ProcessingPipeline, 151 NarrationCore,
87 document-processing, 43 Libro Core, 366 VoiceRelay Core and 185 app cases;
explicit native/private opt-ins retain their skips. All five synthetic helper
traces defer speech weights, promote the same PID and join its reap. First-use
Qwen conversion passes without linking MLX or using weight files. Three repeated
synthetic 200-window tokenizer runs measure a median 1.412 s for the frozen
original and 0.734 s with 12 workers (about 1.9×); these are not actual-book or
real-model performance measurements.

Both ad-hoc workspace Debug/Release builds and all four bundle audits pass using
the verified installed Metal toolchain `com.apple.dt.toolchain.Metal.32023.922.4`.
The reused `.build/WorkspaceDerivedData` is intermediate engineering output, not
the operator's app. Evidence is indexed in
`.local/validation/cpu-preparation-20261103/gate-result.json`; the successful gates
are `full-B796DA22-2326-45C3-B9BD-9BC08666C9B6` and
`release-051B0A21-296E-4A75-ACF3-625438006D22` under `.local/validation/`.
Earlier sandbox-restricted, missing-progress-case and stale-toolchain attempts are
retained separately. The development milestones are
Libro 0.2.0 and VoiceRelay 0.1.1. Actual-book throughput, GUI and listening are
operator-owned under [L21](OPERATOR_VALIDATION.md#libro); the operator builds the
validation app in Xcode with normal signing. No voice model or private ebook was
run for these engineering checks. The opt-in coordinated residency probe still
initializes complete speech models; frontend-only cold residency there remains
service-activation work. VoiceServer HTTP/credentials/default activation remain
unfinished.

## VoiceServer document and review preparation — November 3, 2026

The next opt-in slice carries admitted CPU work through document readers,
progressive Libro previews, detached article review and retained narration-review
operations. Pure text/diagnostic loops share the audio checkpoint hook. PDF pages,
EPUB chapters, document parsing and review PCM/hash writes can pause without
occupying the UI or HTTP executor. Speech inference stays in the MLX helper.
Actual OCR/title/image inference stays outside CPU units; its active-work budget
excludes time waiting for higher-priority admission. Limits still reject excessive
active work. Optional review writes serialize; cancellation joins the work and
cleans only a repair's newly owned take.

Pending article removal now cancels and joins preparation, including an inference
admission wait. Snapshot planning, hashing and encoding precede the database writer
transaction; the final commit rejects changed saved bytes or settings and preserves
existing progress. Synthetic regression checks cover these boundaries without
models, private documents or live services. The full fixture gate passes, including
161 processing-pipeline, 145 Core, 86 document-processing, 41 Libro Core,
366 VoiceRelay Core and 185 VoiceRelay app cases; explicitly opt-in native/private
checks retain their existing skips. Evidence is in
`.local/validation/full-BFBB32B9-35EA-4501-8830-CEF8083B5F63/` and indexed in
`.local/validation/voiceserver-preparation-20261103/fixture-result.json`.
Both ad-hoc Debug/Release workspace builds and all four helper/codec/notices bundle
audits pass. The separate candidate is
`.build/VoiceServerPreparationGate-60D72728-9292-41F5-BE47-CA4233F31DBC/Build/Products/`.
Final fingerprints/results are indexed in the continuation's `gate-result.json`.
[VS01a](OPERATOR_VALIDATION.md#voiceserver-staged-acceptance) owns the pending
preparation/review GUI check, with disposable inputs and an operator handoff in
the continuation folder. No app was launched or prior candidate replaced; archives,
commits and pushes were not performed.

This expands the opt-in seams; default app construction still supplies nil.
Remaining intake/cover and queue-metadata CPU paths, explicit recovery/file-access
UI, retention/repair, HTTP, credentials, Settings and Tailscale remain activation
work. The accepted listening candidate and its clips are preserved.

## VoiceServer maintenance, CPU admission and response codecs — November 3, 2026

The November 2 continuation now passes its final gate. The opt-in owner parks
background CPU work, cancels accepted API work, reaps its helper and joins active
platform leases before model installation/deletion. Stop/Quit join owned operations;
published recordings remain intact if a cancelled completion receipt cannot finish.
Source proofs, narration planning, PCM journals, validation, encoding and publication
run through admitted CPU work. Separate queues keep a suspended finalizer from
blocking live encoding or the UI. This adds no CPU model backend: speech inference
remains in the MLX helper. Some preparation/analysis subcalls and optional review
retention still need complete admission coverage before activation.

Payload-free notification wakeups retain periodic safety checks. Transient waiting
status rejects stale events and preserves progress, errors and manual controls.
Private coordinated/probe IPC is version 6; normal serving IPC stays version 3.
The response codecs retain one resampler/encoder across frames, stream non-seeking
MP3 or mono 24 kHz signed 16-bit little-endian PCM, and terminate on bounds/errors
without replay. VoiceRelay now explicitly embeds/signs the pinned native MP3 codec.

Decoded speech comparisons exposed LAME's preset changing explicit unity scale
to 0.95. A narrow pinned patch removes that multiplier; initialization and bundle
audits now require unity. No compensating gain/normalization/limiter is added.
Completed recordings are unchanged. The final four 24 kHz model comparisons show
MP3 RMS ratios of approximately 0.999–1.002 and correlation above 0.9996; raw PCM
differs by at most one quantization step. Soprano's native 32 kHz conversion is
separately decoded and checked for output rate/frame count; the operator's later
listening acceptance is recorded below.

All 129 feature-focused cases (119 shared, 10 VoiceRelay) pass in the final full
fixtures, including 363 VoiceRelay core and 185 app tests:
`.local/validation/full-27B55398-A19F-4342-AE52-DE83CBDDD07B/`.
Both ad-hoc Debug/Release builds and all four bundle audits pass for
`.build/VoiceServerCodecGate-999D964E-DD61-40BE-B28F-9B4222BE5CB3/Build/Products/`.
All five installed models pass offline initialize-only readiness, exact deferred
checkpoint readback, compatible warm reuse, MP3/PCM export and owned reap. Final
worker/codec/harness fingerprints, decoded measurements and retained failures are
indexed in `.local/validation/voiceserver-continuation-20261102/gate-result.json`;
the folder retains the continuation's November 2 start date.

The operator accepted the paired synthetic `api.wav`/`api-stream.mp3` clips on
November 3: “Audio is all good.” This closes
[VS01 in the operator checklist](OPERATOR_VALIDATION.md#voiceserver-staged-acceptance)
for those offline bounded-unit comparisons. Raw incremental Qwen, long-duration
streaming, GUI, HTTP, Keychain, VPN and distribution acceptance remain separate.
Default constructors still supply nil; recovery/file-access UI, retention/repair,
remaining preparation/review coverage, HTTP, credentials, service Settings and
Tailscale are pending. No app was launched, no earlier operator candidate was
replaced, and no archive, commit or push was performed. Detailed decisions remain
in the [continuation record](VOICESERVER_IMPLEMENTATION_CHECKLIST.md#maintenance-cpu-admission-wakeups-and-streaming-codecs--november-3-2026).

## VoiceServer host admission and app ownership — November 2, 2026

The opt-in coordinator now also owns ranked host inference admission for OCR,
on-device title/image descriptions and explicit local recognition. Queued host work
cannot bypass accepted API demand through a legacy interactive call. Platform
operations retain compatibility locks and ranked demand through actual completion;
Quit refuses new grants and joins outstanding leases. Already-started platform calls
are cooperative, with no native cancellation-latency claim.

Both apps have opt-in constructor bindings for generation/setup/previews and joined
Quit cleanup. Source preparation propagates admission across detached tasks. Setup
now has a genuine initialize-only operation: a registered session alone is not
model readiness. Default constructors still supply no coordinator. CPU loops/hashes,
maintenance, wakeups/status and explicit recovery UI/retention remain activation
prerequisites; HTTP/Settings/Tailscale remain pending. See the
[host-admission record](VOICESERVER_IMPLEMENTATION_CHECKLIST.md#host-inference-and-app-ownership-bindings--november-2-2026).

Ten new synthetic cases pass alongside the earlier 85 feature cases. Full fixtures
pass in `.local/validation/full-56FED339-53F8-4236-88DF-6CC22B53511E/`, including
361 VoiceRelay core and 184 app cases. Fresh ad-hoc Debug/Release builds and four
bundle audits pass for
`.build/VoiceServerHostAdmissionGate-352F839A-9898-4E2E-8B88-8C55F01048A6/Build/Products/`.
All five installed models pass offline initialize-only readiness, deferred
checkpoint readback, warm reuse and owned reap. Evidence/fingerprints are indexed
in `.local/validation/voiceserver-host-admission-20261102/gate-result.json`.
This does not establish native platform handoff, GUI, listening, HTTP or
distribution acceptance. No prior candidate was replaced; no archive, commit or
push was performed.

## VoiceServer opt-in persistence adapters — November 2, 2026

VoiceRelay now fences the actual SQLite checkpoint commit, with validation, hashing,
JSON and writer acquisition outside the registration/epoch fence. A rejected result
rolls back and retries in the same queue run; Stop does not cancel another API job.
Transient receipts are never serialized. Libro's opt-in batch recovery captures
source/destination proofs, ordered inputs, encoding, settings, pronunciation rules,
covers and replacement consent, then reopens verified plans/PCM without new G2P.
Completed/skipped documents never replay; changed sources/outputs fail closed.
Manual pause withdraws priority, and Skip can finish while API work remains active.

Eighty-five feature-focused synthetic cases pass: 80 shared and five VoiceRelay
adapter cases. The apps' default coordinator injection remains nil. Lifecycle,
setup/preview/OCR admission, waiting status, explicit recovery/file-access UI and
retention/repair remain activation prerequisites. HTTP/Settings/Tailscale are not
enabled. See the [persistence record](VOICESERVER_IMPLEMENTATION_CHECKLIST.md#persistence-adapters-and-captured-batch-recovery--november-2-2026)
for scope; prior candidate/native receipts below remain separately dated evidence.

Final full fixtures pass in
`.local/validation/full-53916B16-AC23-4AF0-8178-6BE2996ED767/` (360 VoiceRelay core
and 183 app cases). Fresh ad-hoc Debug/Release builds and four bundle audits pass;
the candidate is
`.build/VoiceServerPersistenceGate-21FDC1FB-CBA9-4BD7-AEDD-6B7F114B1E66/Build/Products/`.
All five installed native models pass deferred checkpoint generation, exact WAV
readback before commit, same-helper reuse and owned reap, with networking denied.
Receipts match the audited Release workers. The consolidated record is
`.local/validation/voiceserver-persistence-20261102/gate-result.json`; the initial
failed fixture barrier and its correction are retained there. No GUI, listening,
protected-file, server or distribution acceptance is implied; no archive, commit
or push was performed.

## VoiceServer coordinated render seam — November 2, 2026

An opt-in app-owned coordinator now connects shared native preparation/generation
to three-rank admission, warm same-app reuse and cross-app unload-before-load.
The helper rechecks priority at each unit launch. A private verified-PCM journal
supports captured-plan reconstruction independently of optional review retention;
the retained-render regression preserves its writer and committed prefix through
streaming preemption. Reopening can reconstruct output without launching inference.
Seventy-three focused synthetic cases pass, including eleven coordinator and seven
journal/render cases, plus final-launch and close/registration regressions.

Both apps keep their current defaults: coordinator injection is nil. VoiceRelay's
final database checkpoint fence, Libro batch/source/destination recovery, app
lifecycle/manual controls and waiting status still need integration before
activation. No HTTP, Settings or Tailscale feature is enabled. See the
[coordinated-render record](VOICESERVER_IMPLEMENTATION_CHECKLIST.md#coordinated-render-and-recovery-seam--november-2-2026)
for scope, provisional bounds and evidence. Earlier native safety receipts below
remain separate from validation of the new host/helper path.

Final full fixtures pass in
`.local/validation/full-8BA606D4-E5E5-42D1-95D8-73AA5313A802/`, including 355
VoiceRelay core tests, 183 app tests and packaging. Debug/Release builds and four
audits pass for isolated CoordinatorGate candidates. All five installed adapters
pass the serial offline coordinator check: prepared transfer, same-helper idle
API handoff/resume and owned reap. Their receipts match audited Release worker
hashes; `.local/validation/voiceserver-coordinator-20261102/gate-result.json`
indexes the evidence. This is separate from active-cancellation timing, listening,
reference/region and long-duration acceptance. No installed candidate was replaced.

## VoiceServer safety gates and shared foundations — November 2, 2026

The three VoiceRelay red assertions are resolved as stale feed metadata/signing
expectations, preserving article-body/author/local-path privacy checks. Full fixtures
pass in `.local/validation/full-C5082A95-69BC-4AC9-BB63-9B5DC50E7E9A/`, including
355 VoiceRelay core tests, 183 app tests and packaging checks. Earlier failed gates
below remain historical evidence, not current outstanding assertion failures.

The probe control reader now remains responsive during owned initialization.
Private probe wire version 4 includes a controlled loaded-weight/pre-admission
barrier, with no job-ready acknowledgement after cancellation/failure. Every
adapter passes seven initialization/EOF phases, nine generation cancellations and
ten short completed requests: 35 phases, 45 cancels and 50 completions in total.
Each helper owns compatibility exclusion through actual unload/reap. Sampled
footprints remain within existing budgets; longer-duration stability is unproven.

The Qwen decoder double-bias hypothesis is confirmed by a model-free actual-layer
regression. The opt-in callback correction reduces full-model direct/stream maximum
PCM difference from 0.2604 to 0.00000276, with identical incremental output after
reset. Ordinary app generation defaults are unchanged. Every bundle audit now
checks the fixed-weight CPU regression as well as Metal. Raw Qwen remains probe-only
pending continuity/listening acceptance; initial bounded Qwen units and unavailable
Orpheus streaming remain the planned policies.

Full fixtures exposed a probe close race in Foundation's unbounded `waitUntilExit`.
A retained sample identifies it; bounded exit callbacks now coalesce close callers
and cover deinitialization. Concurrent close repeats 12 times in regression tests.
The failed run/sample and final fingerprint-checked native summary are retained in
`.local/validation/voiceserver-safety-20261102/`; Debug/Release and four audits pass
for the isolated SafetyGate candidates. No app launch/install, model acquisition,
live service, signing-account or listening acceptance occurred.

Production integration has begun with `SpeechWorkAdmission`, a private bounded
three-rank ticket registry with cross-process kernel liveness and atomic final
rank/compatibility-lock checks, plus `SpeechAttemptFence` for job/epoch commits,
quiescent resumption and preserved verified-index cursors. Fifty-four focused
cases pass, including 12 new admission/compatibility and six commit-fence cases.
The final shared-foundation full run
`.local/validation/full-3E9FB5F0-F42A-4E32-874E-2C03C4CD3504/` passes, followed by
the strengthened same-batch epoch focused check. Separate Debug/Release candidates
and four audits pass in `.local/validation/voiceserver-admission-20261102/`;
the native SafetyGate candidates/receipts are preserved separately.
These shared primitives remain unwired to app coordinators, VoiceRelay persistence
and durable Libro recovery. App serving/scheduling priorities remain unchanged;
HTTP, Settings and Tailscale integration are still pending. The
[checklist](VOICESERVER_IMPLEMENTATION_CHECKLIST.md#initialization-safety-decoder-correction-and-shared-foundations--november-2-2026)
records the native matrix, scope and next integration work.

## VoiceServer live first-unit and reload proof — November 1, 2026

The continuation adds opt-in `firstSentence` / `qwenIncremental` probe modes,
versioned live-first-sentence packing with preserved mappings, an owned synchronous
Qwen callback patch, private probe wire version 2 lifecycle events and a two-helper
native reload driver. App serving, ordinary segmentation and production SpeechIPC
version 3 are unchanged. No service/Settings implementation or app launch is included.

All 24 focused synthetic cases pass. Audited packaged Release helpers pass smaller
first-unit reuse for Kokoro and Chatterbox (resumed first WAV 0.13/0.57 s), and actual
Libro-unload-before-VoiceRelay-load for Kokoro/Qwen (accepted demand to WAV
2.75/4.09 s). The latter requests interrupt first inference in newly loaded helpers:
old cancellation takes 1.65/1.45 s, so warm millisecond observations are not universal
deadlines. Model initialization and transfer remain separate from server/client TTFA.

Qwen incremental lifecycle, sample coverage and reset reuse pass: resumed first WAV
is 0.19 s in the final parity-enforced run, six frames arrive within the first semantic unit, and output is
sample-identical after cancellation/reset. **Incremental continuity does not pass**:
direct-versus-streaming PCM differs by up to 0.2604, starting at subsequent decoder
chunk boundaries despite equal sample counts. A biased convolution-overflow sum
is a source-level hypothesis for the next targeted decoder proof, not a validated
fix. The native harness now fails explicitly on PCM parity failure. Initial Qwen
streaming therefore uses bounded complete utterances; its raw callback stays
probe-only. Orpheus streaming remains unavailable. No listening result is claimed.

Receipts, boundary diagnostics and bundle audits live under
`.local/validation/voiceserver-streaming-20261101/`. Debug/Release builds and all
four audits pass, preserving prior candidates and installed bundles. The full run
`.local/validation/full-600AF0BE-7C33-433F-921B-101F8CEF4EF5/` passes all 24 cases,
other shared/Libro suites and 183 VoiceRelay app tests, and remains red on the same
three unchanged VoiceRelay core assertions below. No commit/push or archive.
The [checklist](VOICESERVER_IMPLEMENTATION_CHECKLIST.md#live-first-unit-incremental-and-reload-gate--authorized-november-1-2026)
records the evidence, revised initial capability policy and remaining initialization,
decoder-parity and broader native safety gates before scheduler integration.

## VoiceServer native feasibility probe — November 1, 2026

The authorized next gate adds explicit helper `--handoff-probe` and native-check
`handoff` modes, shared bounded/versioned controls, an owned joined producer,
one-frame backpressure and helper-owned current/legacy inference exclusion through
GPU drain/unload. The normal app serving/scheduling paths remain unchanged.
The recorded Soprano patch now joins its internal token producer in both consumers;
an iterator ending or a fast cancellation observation alone is insufficient.
Six new control-path tests and the ten first-proof tests pass. The optimized
helper builds, passes its Metal probe and passes native cancellation/reuse plus
lossless first-unit WAV checks for all five installed model adapters, serially
with network denied. No app bundle was installed, launched or replaced.

Final receipts are `*-owned/receipt.json` under
`.local/validation/voiceserver-native-20261101/`; `native-summary.json` aggregates
them. Every run keeps one initialization and the same worker after cancellation.
The summary verifies each worker hash against its packaged Release audit. Soprano
uses Libro's helper and remains Libro-only in model selection. Resumed first-unit
WAV times are 0.48 s Kokoro, 0.70 s Soprano, 3.90 s Qwen,
2.11 s Chatterbox and 25.08 s Orpheus. These local metrics exclude model loading
and do not establish server/client TTFA. Cancel-to-ready spans 2.2–55.6 ms for the
single early injection per adapter, not a production deadline.

Orpheus takes 79.47 s to generate/publish 38.74 s of audio in the resumed probe.
The design therefore gates initial Orpheus streaming as unavailable; complete-file
API support remains planned. At this earlier gate, smaller live first units,
owned incremental Qwen output and actual cross-app reload cost were still open;
the follow-up above records their implementation and partial acceptance. Broader
cancellation positions/settings and listening remain open. Chatterbox's regenerated hashes differ; deterministic
real-model regeneration is not required. The
[checklist](VOICESERVER_IMPLEMENTATION_CHECKLIST.md#native-feasibility-gate--authorized-november-1-2026)
records the full table, preserved failed attempts and revised design.

Patched full fixtures in
`.local/validation/full-0F9381B3-2943-485D-84C4-2C3218A136B4/` pass all 16 probe
tests and the other shared/Libro/app suites; the same three unchanged VoiceRelay
core assertions keep the full gate red. Debug/Release workspace builds and all
four bundle audits pass, with logs in the native evidence directory. Isolated
ad-hoc candidates are under
`.build/VoiceServerNativeGate-5D767E69-3CC5-443A-A060-C4F6AC1E31E7/Build/Products/`;
archives were unrequested and no operator bundle was replaced.

## VoiceServer first synthetic proof — November 1, 2026

The authorized VS00 synthetic proof is implemented in NarrationFixtureWorker and
NarrationCoreTests. Two isolated app clients and their fake helpers exercise
API > Libro > Podcasts, epoch rollback, same-app reuse, cross-app unload-before-load,
FIFO API work, complete-file yielding, pause/Stop, requester loss and orphan drain.
Checkpoint hashes survive suspension/reopening; an independent trace audit checks
exclusive residency/generation and quiescence/reset ordering. The
[checklist](VOICESERVER_IMPLEMENTATION_CHECKLIST.md#vs00-proof-results-and-design-refinements--november-1-2026)
records the trace, reproduction and design refinements.

All ten focused proof tests pass and pass again within
`.local/validation/full-D0553F57-D1C9-416D-A7CE-424E8E9A266E/`. That full gate fails
on three assertions in unchanged VoiceRelay core tests (two feed-content checks
and the signing include expectation); shared/Libro suites and 183 VoiceRelay app
tests pass. Subsequent packaging did not run. The checklist names the failures;
they were retained without unrelated publishing/signing changes.

That first proof is fixture-only state-machine evidence. App priority, normal serving IPC and
audio behavior are unchanged; HTTP and Settings remain unimplemented. Native
cancellation/reuse/first-audio feasibility remains a separate operator-owned gate
before broad integration. That first proof used no models, app launches or live services.

## Automatic speech-setup validation — current

Speech setup checks are now automatic/background for both apps via a shared
`SpeechSetupValidation` controller (ProcessingPipeline): one local inventory
plus one offline initialization per selected model/voice/language/root/revision,
cancelled-and-joined whenever selection or conflicting owned work supersedes it.
Manual Check controls are removed; the Voice Model heading shows Validating, a
green Ready, or Repair local model on failure. Validation evidence: focused
suites plus frozen `.local/validation/full-2445BBB4-B18B-4FF9-A93E-8672EB7F1AE7`
(full fixture gate, run before the follow-up review fixes) and
`.local/validation/release-B5918E3A-A227-427A-B132-A0E60D397B3E` (Debug+Release
workspace builds and all four bundle audits after those fixes); focused rework
suites: SpeechSetupValidationTests 15/15, NarrationSettingsTests 16/16 and
VoiceRelay app fixtures 20/20; operator GUI/listening acceptance unperformed.

## VoiceRelay menu and publishing history — current

The menu popover keeps its overall status first, then shows **Last published**
with the local date and time of the most recent confirmed feed update at the
current destination, or **Not recorded** for older/new destinations. The durable
delivery ledger records that timestamp only after the uploaded feed's exact
readback; checks, reconciliation, media-only work and failed attempts do not
count as publication. The dropdown now uses **Open VoiceRelay** for the Articles
workspace and orders **Settings**, **Copy Podcast URL**, then **Quit VoiceRelay**.
The library outbox is labelled **Upload Queue**. Libro's Voice Model heading no
longer duplicates section help; model details remain beside the model picker.

Focused publication-history, recovery, projection and menu tests pass, including
the complete affected 121 VoiceRelay core and 146 app-test selection. The shared
header-sizing regression, documentation checks and a Debug `Build Both Apps`
workspace build pass in `.local/validation/menu-polish-review-20261031/`. GUI,
clipboard, server and publishing acceptance remain operator-owned; no live server
was contacted.

## Mandatory semantic phrasing and shared setup banner — current

Semantic phrasing is now the only production preparation path for all five
product models, superseding the Kokoro-only activation below. Saved
`SpeechSettings.planning` values decode as inert compatibility metadata and no
longer change effective preparation: Kokoro selects its current policy, every
other model selects native text, and every non-Kokoro narration version carries
`semantic-boundaries-1`. Incompatible unfinished plans reprepare under the
current identity; completed recordings and prior comparison pages are
preserved. New baseline-versus-semantic comparisons are retired.

Missing selected models now present one shared **Speech Setup Required**
header: above Libro's main voice controls, at the top of VoiceRelay's Voice
Model settings, and in VoiceRelay's workspace readiness area. It owns the
Download/Cancel action, scope-aware byte progress, separate checking and
validation states, retryable failures and reduce-motion-aware collapse; the
former inline download arrow and phrasing toggle are removed. Model details
stay beside the visible model menu and format pickers size to their content.

Final full fixtures pass in `.local/validation/full-C42389FC-203E-446B-90E5-E04912A61DD7/`.
Final Debug/Release workspace builds and all four bundle audits pass in
`.local/validation/release-D426E790-AA69-4F2B-A720-1894B0508C7B/`; archives were
skipped. The standalone benchmark's 27 fixtures passed; its output was not saved
to a validation directory. GUI and listening acceptance were not performed; no
models were downloaded, no live services used and no apps installed or replaced.

## Mandatory Kokoro semantic phrasing — October 30

Following the operator's paired listening and explicit activation decision, new
Kokoro narration always uses semantic phrasing in both apps. Its experiment switch
is removed; older saved preferences cannot disable the policy. Other models retain
their opt-in switch and existing defaults. Switching away from Kokoro does not
implicitly enable the experiment for another model.

`phoneme-semantic-compounds-2` also protects letter-to-letter compounds from internal
packing splits and converts their aligned hyphen pause phones to word separators.
Source hyphens/mappings, real dashes, numeric handling, audio levels and the hard
510-phone ceiling are preserved. Incompatible unfinished plans are reprepared;
old completed recordings and bundled samples remain historical. Explicit review
repair/continuation prepares only generated passages with current packing and
reuses unchanged verified PCM. New phrasing comparisons exclude Kokoro; existing
blind pages and choices remain readable. Compound naturalness and current UI
remain operator checks in B09.

Full fixtures pass in `.local/validation/full-B94B7AEB-961C-4DBB-9A0A-E994A54CB55C/`.
Final Debug/Release workspace builds and all four bundle audits pass in
`.local/validation/release-2E09E733-7746-475C-ADE8-4C948514F33C/`; archives were skipped.
The full rerun includes the corrected source-only checkpoint compatibility cases.
All 27 benchmark fixtures pass; an inert-helper routing check verifies exactly
four non-Kokoro models, eight retained expected failures and no invalid audio.
Each packaged helper passed 36 frontend cases in both US and GB English, including
ASCII/Unicode compounds. Two native compound WAVs passed independent finite-PCM,
frame/hash, source-coverage and no-dash-phone checks. Private receipts and short
listening samples are under `.local/kokoro-semantic/`. No models were downloaded,
installed apps replaced or live services used.

## Long-form narration quality — October 30

Operator paired listening is now recorded in the
[listening results](LONGFORM_QUALITY_LISTENING_RESULTS.md): semantic phrasing was
preferred for Kokoro/Heart; all four other pairs were rated Same. Contextual
read/lead, selected unit/time pronunciations, paragraph timing and Ryan's pacing
remain follow-up issues. This supports considering Kokoro-only activation on
this evidence; the initial import did not change defaults. The subsequent operator
decision above activates it for Kokoro. B09 remains partial because GUI,
recognition and broader pronunciation acceptance were not reported.

The authorized [implementation plan](LONGFORM_QUALITY_IMPLEMENTATION_PLAN.md) is
implemented across the shared packages and both apps. Semantic phrasing is now
mandatory for every model, including saved legacy/nil planning values, previews,
resume/review repair and direct native sessions; the former opt-in control and
inline download action are retired in favour of the shared setup banner.
Native-text English spoken-form expansions and private review retention remain
opt-in. Scoped language/document/model rules, trusted aligned
Kokoro phones, sentence-context previews, name-review drafts and optional Qwen
delivery presets share one implementation. See [behavior and limits](LONGFORM_QUALITY.md).

Private immutable plans and bounded chunk journals support read-only duration,
silence/repetition checks, installed-only local Apple recognition, explicit
selective/current-rule regeneration, continuation of missing passages and a new
WAV export with measured frame intervals. Repairs stream one passage at a time.
Corrupt frame/hash metadata fails before byte accounting. Source records,
finished audio, publishing and authoritative transcript timing remain independent.

The new Swift product-pipeline comparison rendered five matched pairs (ten native
Float32 WAVs), with no failed takes in the final run. Native US/GB checks also
validated scoped phone overrides, preserved written text and rendered audio.
The first native run exposed Qwen's hidden input-length-derived output cap; an
opt-in adapter now honors the already-declared 4,096-token ceiling. The same
fixed-seed passage completed with accepted and candidate preparation afterward.
Its generation identity changed; memory, timeout, duration and clean-EOS guards
remain active. Old recordings and failed-run evidence are preserved.

Final full fixtures pass in
`.local/validation/full-7956855B-3686-4B6D-82EF-999B525C2660/`; final Debug/Release
builds and all four bundle audits pass in
`.local/validation/release-4BE588B8-38A7-4043-92C3-C15C1EBC6BF2/`.
The benchmark's 27 isolated fixtures pass. An inert failing-helper run verifies
four preserved failure receipts, continuation and no invalid listening clips.
Native audio hashes, finite samples, frame counts, matched settings and anonymous
page data pass independent inspection. Private receipts/source fingerprints are
under `.local/longform-quality/`. Paired audio was rendered before the last
cache-integrity/editor/streaming-repair refinements; generation source is unchanged,
and final packaged frontend checks remain separate receipts.

The listening page is
`.local/tts-model-benchmark/phrasing-20261030-final/comparison.html`.
Open it directly; identities remain outside page data until an explicit final
reveal. Current ad-hoc app candidates remain under
`.build/WorkspaceDerivedData/Build/Products/Release/`. No installed app was replaced,
no models downloaded and no live-source/server operation performed. Archives were
skipped. GUI, local recognition availability and listening are operator-owned B09;
automated recording checks alone do not establish that the candidate sounds better.

## Libro voice-control layout and Qwen help — October 29

Libro's main-window voice controls now use a tightly fitted wrapper, with 6pt
vertical and 4pt horizontal spacing scaled to text size. Model/Voice stay anchored
to the top/leading edge; simpler models shrink the header, while narrow layouts
place Output format below the voice controls and scroll either group when needed.
The inline Format label keeps its dropdown level with Model. Qwen's separate
Native row is removed in both apps; the native language is bold and star-marked
inside the Language menu, with regional detail in hover/accessibility help.
Settings remains focused on model storage/setup. Both apps share the Qwen Delivery
label/field tooltip explaining tone/pacing cues, default delivery when blank and
the 128-character limit. Their shared controls/scrollers retain intrinsic height.

All 14 NarrationUI tests passed, including offscreen sizing across models,
control states, narrow widths and text sizes, plus native-language emphasis for
all Qwen voices and regional Chinese variants. The quick gate, Debug/Release
workspace builds and all four bundle audits passed; archives were skipped.
Current build receipt:
`.local/validation/release-E68D2341-3E0A-442F-AF54-924FD749B21B/`.
Focused logs/source hashes are in `.local/voice-menu-labels/`. No installed app
was replaced; visual/hover acceptance remains operator-owned.

## Duplicate article management — October 29

VoiceRelay now selects one readable copy of duplicate Reading List articles,
using original URL or normalized title plus original website. Fuller extracted
prose wins; within 5% of the longest copy the newest save wins. Inactive copies
remain gray and labelled in All Articles. Extraction evidence and handled save
IDs commit with admission, preserving suppression across source refresh, restart,
queue reset and audio removal. A genuinely new save or explicit active-copy
requeue can create fresh audio with current settings.

Intentional replacements preserve old history while the new audio and feed
membership are confirmed. A bounded second feed publication removes older
matching episodes before owned audio/transcript deletion. Failed delivery and
interrupted cleanup remain recoverable. Legacy source/date backfill and Safari
entry retargeting preserve their identity boundaries; managed speech resumes its
captured episode ID rather than a mutable URL slot. See the [user guide](../VoiceRelay/docs/USER_GUIDE.md#duplicate-articles)
and [admission contract](../VoiceRelay/docs/ARCHITECTURE.md#duplicate-admission-and-replacement).

The complete VoiceRelay suites passed 346 core and 175 app tests. Final focused
checks passed 20 tests, including missing superseded temporary audio, legacy
metadata/date recovery, unchanged-save suppression and replacement failures for
both matching and differing source URLs. The quick gate and documentation/link
checks passed. Final Debug/Release workspace builds and all four bundle audits
passed in `.local/validation/release-4106C2E3-8477-440C-999A-19F942E783D4/`.
Archives were unrequested. Synthetic logs and source hashes are retained under
`.local/article-duplicates/`. Ad-hoc candidates remain under
`.build/WorkspaceDerivedData/Build/Products/{Debug,Release}/`; no installed app,
Safari source or real server content was changed. Real Safari, GUI, listening and
live-server acceptance remain operator-owned under V06.

## Immediate Server Audio removal — October 29

VoiceRelay now hides accepted Server Audio removals immediately, without row
animation or a visible in-process row. A serial owned local-removal queue accepts
further clicks while preserving unrelated rows/selection. The lower status bar
shows pending cleanup. Canonical episode records and feed-before-delete safety
remain unchanged; this is optimistic presentation, not server confirmation.

Library refreshes and delivery snapshots cannot resurrect active hidden rows.
Local failures and completed server attempts with unfinished work restore the
affected items; newer requests remain hidden until their own follow-up attempt.
Publishing-off/unavailable work is restored as pending, and quit joins/cancels the
owned queue without running later requests. Upload-copy deletion remains exclusive.

All 174 VoiceRelay app tests pass, including delayed server DELETE, rapid local
clicks, polling, duplicate/stale actions, ownership-validation failure, feed-update
failure, Publishing disabled, follow-up drains, preserved selection and quit.
Synthetic gates also verify that stalled cleanup leaves the MainActor responsive.
Quick static/tooling/docs pass in
`.local/validation/quick-7972FDC2-1F87-46DF-96F7-47E5E808C6D0/`.
Debug/Release workspace builds and four bundle audits pass in
`.local/validation/release-9A2CFFEA-11E5-4832-AA70-702006871A80/`.
Private logs are `.local/optimistic-server-audio-removal/`. Archives were skipped;
no real server, Keychain credentials or installed app was used/replaced. Actual
list smoothness and live-server acceptance remain operator-owned through V14.

## Compact voice controls and inventory columns — October 29

Both apps now keep file sizes and deletion exclusively in Downloaded models.
The shared voice picker has a narrower label/metadata area and only download
when missing plus adjacent model details; cached-model repair remains in the
details popover. The common control width drops from 376pt to 296pt, scaling with
text size, while preserving common menu positions and dynamic section height.

Downloaded-model rows use fixed name, right-aligned size and trash columns
(120/80/32pt with 8pt gaps, scaled to text size) directly below folder controls.
They no longer stretch to the window edge. Narrow windows scroll the table;
imported folders have no delete action. Folder changes invalidate pending targets,
the confirmed root/model is rechecked before deletion, and app activation refreshes
the inventory. Shared storage leases and preservation of recordings remain intact.
This supersedes earlier picker-row size/trash presentation below.

Seventeen focused tests pass: thirteen shared presentation/storage regressions
and four VoiceRelay Settings/health regressions. Inert sizing checks cover long
model names, small/large file sizes, imported rows, text enlargement and horizontal
scrollers, without invoking actions or reading real model/profile storage.
The initial 56pt label column failed the Language-label fit check; the final
60pt column passes. Quick static/tooling/docs pass in
`.local/validation/quick-C2C31E63-ED74-49E1-931B-FF0C5A6B70D8/`.
Debug/Release workspace builds and four bundle audits pass in
`.local/validation/release-EA161412-07CD-44B0-B53C-2EA525F2D3DC/`.
Private logs are `.local/model-inventory-columns/`. Archives were skipped;
actual GUI/deletion-flow acceptance remains operator-owned.

## Unified concise model setup and startup defaults — October 29

Both apps now display the same Model Setup window from NarrationUI, with one
short local-speech explanation, shared status/progress, custom-folder selection,
Install Model/Check Model, Not Now and Cancel. There are no app-specific content
slots, paths or startup controls. The common component dismisses on verified
readiness; apps retain the owned download/check/cancel operations. Libro also
joins readiness checks on cancellation and keeps preflight failures visible.

VoiceRelay requests main-app login startup once for fresh configurations. General
Settings is the only place for the toggle. Existing preferences/library state,
explicit opt-outs, OS approval/revocation and failed enrollment are preserved;
there is no automatic retry on later launches. Tests use fake login services,
not real registration. Libro's idle status cell is blank while progress and
diagnostics remain visible during work.

Twenty-four focused tests pass: twelve shared presentation/storage regressions
(including compact setup sizing and expanded errors) and twelve VoiceRelay
onboarding/login/Settings regressions. Quick static/tooling/docs pass in
`.local/validation/quick-06FCFA46-E991-4024-BA2D-13D1AD86BF7F/`.
Debug/Release workspace builds and four bundle audits pass in
`.local/validation/release-A9042BE2-EAAB-4A53-A799-4199827C142F/`.
Private evidence is `.local/shared-model-setup/`. Archives were skipped; actual
signed-app login/reboot behavior and full GUI acceptance remain operator-owned.

## Tighter control spacing — October 29

Both apps now use 6pt row gaps and 4pt column gaps in the shared model chooser,
scaled to text size. The column gaps are halved from 8pt, including the gaps
between storage action, size and info. The section's width is reduced accordingly;
Libro also halves the gap to its output-format column from 16pt to 8pt.
The section still fits only the active model's controls and keeps common menu
alignment. This supersedes the 8pt row spacing in the earlier revision below.

All eleven shared tests pass, including 60 inert offscreen model/text/playback
layouts. Static/tooling/docs pass in
`.local/validation/quick-2766DB3D-08D5-40C2-BBE4-046F5B029A8D/`.
Debug/Release workspace builds and four bundle audits pass in
`.local/validation/release-7306D90B-D4ED-4013-ACAD-A94F57127A69/`.
Private logs are in `.local/model-controls-spacing/`. Archives were skipped;
GUI acceptance remains operator-owned.

## Compact section height — October 29

The shared model chooser now sizes vertically to only the selected model's
controls in both apps. It no longer measures/reserves invisible options from
other models. Model and Voice retain their top/left columns; options and Sample
initially followed with 8pt row gaps (previously 16pt); the later spacing revision
above tightens these further. Simpler models
leave more room for the surrounding content. This supersedes the fixed panel
height in the earlier row/layout revisions below.

Eleven shared tests pass, including 60 inert offscreen layouts checking variable
height, common width, playback/busy-state stability and enlarged text. No real
model/profile reads, actions or app windows are needed for these component checks.
Static/tooling/docs pass in
`.local/validation/quick-9A26FA75-64C9-4600-A556-6D231442E293/`.
Debug/Release workspace builds and four bundle audits pass in
`.local/validation/release-BC631ECB-56DA-4F5E-B2A8-84DBE5927C3C/`.
Private logs are under `.local/model-controls-fit/`. Archives were skipped;
full-app GUI acceptance remains operator-owned.

## Recommended starting model — October 29

Both apps retain Kokoro with Heart at 1.0× for fresh preferences. The shared model
picker now labels it **Kokoro (Recommended)**, with the quality/speed/memory
tradeoff explained in its details. Existing saved model choices keep precedence.
The recommendation fits the fixed picker column at the supported text sizes.
See [model selection](MODEL_SELECTION.md).

Fifteen focused shared/Libro/VoiceRelay tests pass, covering defaults, saved
choices and inert layout sizing. Static/documentation/tooling checks, both
workspace configurations and all four bundle audits pass. Evidence is under
`.local/kokoro-recommendation/` and
`.local/validation/release-5C907257-E505-45C2-BBE5-7D6A0F5A43C9/`.
Archives were skipped; GUI acceptance remains operator-owned.

## Shared fresh-start speech setup

October 28 consolidates both onboarding screens in NarrationUI's
`SpeechSetupOnboardingView`, using VoiceRelay's layout, installation explanation,
progress and primary actions. Libro retains Choose Custom Model Folder and preparation
details; VoiceRelay retained optional login startup in that revision. The October 29
unified concise setup revision above supersedes those app-specific content slots.
App-owned detection, cancellation,
verification/dismissal and existing model selections/cache remain unchanged. Synthetic
inert-view fixtures cover missing, busy, ready, cancelled and failed states without
running actions. Four shared fixtures and four VoiceRelay onboarding/retry/offline
fixtures pass. Debug and Release builds of both apps and all four bundle audits pass
(ad-hoc engineering signatures, embedded helper/resources and offline Metal probes).
Evidence:
`.local/validation/quick-50340149-243B-485F-83B0-6C1EB1355D86/summary.json`,
`.local/validation/quick-ADFE7223-00C4-4E96-BD71-0F58763146A2/summary.json` and
`.local/validation/release-537C9702-EA6A-4EE6-A3FF-3C16BB68D844/summary.json`.
The initial quick run (`quick-A57BE192-4997-44F1-87EB-87F3EDBDDA82`) stopped before
tests because Xcode's Metal shim missed the installed compiler. The passing runs
used the verified command-local `TOOLCHAINS=com.apple.dt.toolchain.Metal.32023.921.5`
selection documented in contributor setup; no component/model download or global
toolchain change was needed. Validation products remain in
`.build/WorkspaceDerivedData/Build/Products/{Debug,Release}/`, separate from the
running Xcode-built VoiceRelay app. Archives and the full fixture gate were not run
for this presentation-only revision. GUI/Canvas and real download/cancel/retry acceptance remain operator-owned through
L01/V01 in [the operator checklist](OPERATOR_VALIDATION.md).

## Libro whole-app review fixes

October 27 implementation addresses source-folder output protection, exclusive
atomic publication for unapproved destinations, persistent validated model/voice/
speed preferences, owned cancellable file drops and joined scanner replacement.
Shared queue admission validates names/collisions once; safety boundaries validate
the current target while refreshing source and inode protections, avoiding repeated
whole-batch planning and quadratic path-prefix comparisons.

The [implementation plan](LIBRO_REVIEW_FIX_PLAN.md) records the scope. The full
fixture gate passes, including 38 LibroCore, 328 VoiceRelay core and 166 app tests,
shared/static/packaging checks and the new source/publication/import regressions.
Existing private-document/native opt-ins remain skips. Evidence is
`.local/validation/full-C362DC1E-6FB1-4168-B1C5-143E6D4F0352/summary.json`.
Debug and Release workspace builds and four bundle audits pass. Products are in
`.build/LibroReviewFixes-20261027/Build/Products/{Debug,Release}/`; reports in
`.local/libro-fixes/` verify helper-only MLX, resources, codec, signatures and offline
Metal readiness. These are isolated ad-hoc engineering builds, with no installed
bundle replaced. GUI/listening, actual documents,
protected-file providers and signing-account acceptance remain operator-owned.

## VoiceRelay whole-app review fixes

October 26–27 implementation addresses all eight VoiceRelay review findings: exact
destination/path authority for retirement (including stale ledger intent),
cancellation when Publishing is disabled, targeted deletion-owner updates,
URL-based Reading List removal, original publisher metadata for archived articles,
HTML headline/slug preservation with PDF filename recovery, captured per-episode
pause assembly after helper/checkpoint reuse, and public transcript-link remapping.
Encoding version 3 rebuilds unfinished scratch from compatible lossless checkpoints;
completed and verified already-placed recordings stay unchanged.

The [implementation plan](VOICERELAY_REVIEW_FIX_PLAN.md) records stages and evidence.
Focused regressions cover migration, source identity, pauses and disablement.
The October 27 follow-up also keeps failed
transcript-only removals visible and preserves their error in either deletion
order; listing history leaves corrupt ledgers untouched.
Reading List callbacks stop/join obsolete speech before purging, rebind a surviving
duplicate's source association and admit replacement URLs even during active work
or after the old URL failed earlier in the session. Failure suppression follows
source URLs, not reusable Safari entry IDs.

The final full fixture gate passes, including 328 VoiceRelay core tests, 166 app
tests and all shared/Libro/static/packaging suites. Existing opt-in private/native
cases remain skips. Evidence is
`.local/validation/full-0F216836-5CB5-47F8-8A04-E9E1113F9997/`.
Debug and Release workspace builds and all four bundle/signature/resource/Metal
audits pass for the final source. Ad-hoc candidates use
`.build/VoiceRelayReviewFixes-20261026/Build/Products/{Debug,Release}/`; build/audit
logs are under `.local/review-fixes/`. Final static/documentation checks also pass.
No live library, service or installed operator app has been modified.

## VoiceRelay timed episode transcripts

October 25 implementation adds General → Episode transcripts → Publish timed
transcripts, default-on and captured for newly queued articles. Historical jobs
without a captured choice and finished recordings stay unchanged. The shared
native AAC encoder reports measured input intervals after resampling and actual
gap insertion. VoiceRelay uses final prepared text to produce bounded WebVTT cues
at synthesis-segment granularity, without ASR, word-time estimates or audio gain.

Transcript text, audio/content hashes and independent retry state persist with
episode metadata through encoding resume, cache cleanup and library backup.
Authenticated sidecar readback precedes a standard `podcast:transcript` RSS link.
Failures leave audio/other entries publishable; Uploads retains transcript retry
and pending-feed states. Namespace-aware recovery preserves supplied references;
retirement removes only owned current-destination sidecars after feed removal.

Eight focused transcript fixtures and the persisted-preference app test pass,
covering default/legacy/off settings, cue escaping and measured intervals,
encoding resume, backup, upload readback, cancellation, retry, host changes,
server recovery, feed failure and removal ordering. Ten synthetic shared audio
fixtures pass; the explicit captured-native-audio test remains an opt-in skip.
The full project fixture gate also passes, including 319 VoiceRelay core tests,
161 app tests, shared/Libro suites and synthetic packaging regressions. Retained
evidence is `.local/validation/full-7BFF03FC-089E-4159-A5A6-3071743A21F3/`.
Debug and Release workspace builds and all four bundle/signature/resource/Metal
audits pass. These ad-hoc engineering candidates are in the separate
`.build/TranscriptValidation-20261025/Build/Products/{Debug,Release}/` directory;
no operator app was installed or launched. Local logs use the
`.local/transcript-workspace-` and `.local/transcript-<app>-` prefixes.
Live host MIME/access control, GUI, listening and installed Overcast TestFlight behavior remain
operator acceptance [V22](OPERATOR_VALIDATION.md#voicerelay).

## Voice-selection rows — October 29

Both apps now use the supplied row-based template through the shared
SpeechModelControls: Model (with download/delete, size and info), Voice,
model-specific options and Play Sample. All rows are left-aligned with uniform,
text-size-aware spacing. Picker frames explicitly align to the leading edge.
Kokoro's speed value and Stepper stay together in the value column. Qwen's
Native/Language/Delivery rows initially shared that alignment. The current
revision above replaces Native with language-menu emphasis; Chatterbox import
remains a full row beneath Voice. Unsupported parameters are omitted.

Play Sample is inside the shared component, with app-owned playback/enabled state
and callbacks; separate app-local sample columns/rows are removed. Active options
and Sample originally flowed together with reserved space afterward to keep the
outer panel height steady. The later compact-height revision above removes that
reservation and tightens spacing while preserving the common menu anchors. Input
and sample enablement remain separate, preserving VoiceRelay's bundled playback
while model controls are busy. Existing parameters, recorded audio and cache
management behavior remain unchanged.

Eleven shared tests and six VoiceRelay integration tests pass. Offscreen checks
compare all five models at four text settings and three input/playback states
(60 inert layouts), verify stable envelopes and enlarged text sizing, and compare
compact versus labelled speed-control measurements. They open no app windows,
read no real model/profile storage and invoke no actions. Static/tooling/docs pass
in `.local/validation/quick-F64AE9A8-DB8C-4E70-A888-DCD2A2FFED8D/`.
Final Debug/Release workspace builds and all four bundle audits pass in
`.local/validation/release-31A3C5C4-2FA1-4142-BDD2-CE3A9729B5DA/`.
Archives are unrequested; GUI/keyboard/listening acceptance remains operator-owned.
Current ad-hoc candidates are
`.build/WorkspaceDerivedData/Build/Products/Release/Libro.app` and
`VoiceRelay.app` in the same folder, with parallel Debug products. Private final
logs/source digests are in `.local/model-controls-rows/`. The earlier
`release-5FF2259C-E2DC-4300-83E6-2A4FC0AD2598` pass preceded the final explicit
picker alignment; it is not the final-source receipt. No installed app or actual
model cache was replaced by validation.

## Stable model-selection layout — October 28

Both apps now pin Model and Voice to common, text-size-aware native Grid columns.
Chatterbox uses the same visible Voice label and menu position while retaining
reference-voice accessibility context. Storage action, size and details also use
stable columns. That revision used a hidden, inert set of supported parameter
variants to reserve the largest natural parameter area below the common menus.
The October 29 compact-height revision above removes that reservation. Errors can
still expand below the controls rather than being clipped.

That revision anchored the header to its leading edge and top-aligned sample and
output columns; the October 29 row template above supersedes the sample column. Fixed field/sample widths prevent model changes from selecting a
different narrow-window layout. Speaking parameters, saved choices, files and model
installation/deletion behavior are unchanged.

Ten shared presentation/storage tests and six VoiceRelay integration regressions
pass. One offscreen synthetic layout case measures all five models at 80%, 100%,
200% and an accessibility text size, verifies equal normal panel dimensions across
models and verifies enlargement at 200%, without invoking actions, opening app
windows or reading real model/profile storage. These measurements are component
regressions, not full-app GUI acceptance. Static/tooling/docs pass in
`.local/validation/quick-2D15ECD7-2C8D-4861-A67E-923834D2708B/`.
Both workspace configurations and all four bundle audits pass in
`.local/validation/release-73975CC1-95CB-4299-8F65-AC2B74CF3B81/`.
Archives were explicitly unrequested for that revision. Those receipts predate
the row template above; private logs/source digests are in
`.local/model-controls-stable/`. GUI, keyboard and
listening acceptance remain operator-owned; no installed app was replaced.

## Compact shared model controls — October 28

Both apps now use the same compact model row: an icon-only Download action becomes
trash when cached model files are present, local/estimated size sits beside it,
and the trailing ⓘ opens the description and generation-speed/narration-quality
meters. Inline stats cards are removed. The details popover retains Download
missing files for repair or additional language resources without deleting weights.

Selected-cache inventory runs off the UI actor and refreshes after installation,
deletion, selection/folder changes and app activation. Late or interrupted scans
cannot enable actions for the wrong selection. Confirmed deletion uses the existing
app-owned maintenance task and shared storage lease; in-use failures keep the
cached model, and imported folders remain read-only. Original recordings,
reference voices and unrelated repositories remain protected. No user cache or
installed app was modified during validation.

The compact-control revision passed nine shared UI/storage-state cases, eight native
storage fixtures and six VoiceRelay Settings/integration cases. The opt-in actual
model-generation case is skipped; audio generation was unchanged. Static/tooling
checks pass in `.local/validation/quick-F6C971A5-8361-441A-B5B4-99E1CAE65AAB/`.
Both workspace configurations and all four bundle audits passed for that source
in `.local/validation/release-80BB9C83-7252-4D54-9617-F5DA45AC940F/`.
Those receipts predate the stable-layout revision above; archives were unrequested.
Private logs/source digests are in `.local/model-controls-compact/`. GUI, keyboard and
real-cache acceptance remain operator-owned.

## VoiceRelay Voice Model Settings — October 28

VoiceRelay now has General, Voice Model, Pronunciation, Publishing and
Troubleshooting panes. Voice Model owns model/voice/speed selection, Download,
guidance, samples, installed-model storage and offline setup checks. These controls
are removed from Articles and General. Speech warnings and onboarding direct users
to Voice Model. The Settings window has a 540×680 ideal size with adaptive compact
navigation at narrow widths. Both apps now use the compact shared model row
with download/delete and size; the trailing ⓘ opens model details and meters. Existing preferences and captured jobs are
unchanged.

The original tab relocation, before the compact controls above, passed six
VoiceRelay regressions and four shared UI cases. Static/docs and tooling passed in
`.local/validation/quick-65CD8E02-E03D-4BF4-9E2A-32B43928AA48/`.
Both workspace configurations and all four bundle audits pass in
`.local/validation/release-1E11AF54-4FAF-4DEE-9602-19753D9E5393/`, with archives
explicitly unrequested. Those receipts predate the compact-row revision above;
GUI/keyboard acceptance remains operator-owned. Private evidence is in
`.local/voice-model-settings/`; the earlier cache/native receipts below retain
their original scope.

## Model controls and shared cache — October 28

Both apps now use icon-only download/delete, adjacent size, and an on-demand
model-details/meter popover. Inline stats panels and repeated Settings pickers are removed.
VoiceRelay selection/preview controls live in Settings → Voice Model; Libro keeps its main
batch controls. Section help is shorter while retaining consequential privacy and
deletion information.

New installations use the pinned HuggingFace library's standard shared cache;
explicit custom storage choices and legacy workspaces remain supported. Models
settings (Libro) and Voice Model (VoiceRelay) list downloaded models, allocated disk
sizes and confirmed deletion, plus folder override/default controls. Read-only
imports remain separate. Shared read leases cover complete sessions/installations;
deletion needs exclusive access and preserves audio, references and unrelated
repositories. See [model storage](MODEL_SELECTION.md#model-storage).

Fresh offline standard-cache installation, speech, snapshot-integrity and deletion
checks pass for Kokoro, Qwen, Chatterbox and Orpheus. These opt-in checks use copied
public model assets in temporary caches, shared background inference admission and
network-denied helpers. The user's actual cache and open Libro build were not
modified. Fresh installation also exposed nondeterministic JSON key ordering in
SDK-generated tokenizers; pinned structural digests now validate identical content
without relying on object-key order. Remote input hashes and acoustic identities
are unchanged. Evidence is under `.local/model-storage-validation/`.

The model-storage implementation’s full fixture gate passed at
`.local/validation/full-E43F4723-68B2-459B-906D-9EC223F17325/`. Storage migration
is one-time: explicitly selecting a former automatic folder afterward persists
across relaunch. Default-cache installs keep the override unset, while custom
folders remain explicit. Routine validation now supports `--skip-archives`,
retaining both workspace configurations and their four bundle audits; archive
checks remain available for distribution changes and explicit release validation.

The model-storage implementation’s Debug/Release builds and four bundle audits passed in
`.local/validation/release-DBD0321A-79CD-4A41-8565-751307F17B1D/`.
Archives were explicitly unrequested for that snapshot. Ad-hoc app
candidates are `.build/WorkspaceDerivedData/Build/Products/Release/Libro.app`
and `VoiceRelay.app` in the same folder (with parallel Debug products).
The earlier `release-8A90EA8C-0298-457D-B01D-F06048025A65` archive gate passed
before the final preference cleanup; those archives are historical, not the
current candidates. GUI/accessibility and signed release acceptance remain open.

## Shared model integration — October 27–28

Both apps now share Qwen3-TTS 1.7B CustomVoice (nine presets/ten languages),
Chatterbox Turbo (default and local immutable reference voices) and Orpheus 3B
(eight English presets), while retaining existing defaults and Kokoro/Soprano
behavior. NativeSpeech owns pinned primary/auxiliary inventories and static
speed/quality guidance; NarrationUI owns the common controls. Queued articles
capture the full model/voice/language/style selection. The [model guide](MODEL_SELECTION.md)
describes installation, previews, RAM requirements and reference backup limits.

The final full fixture gate passes: shared tests, 38 LibroCore tests, 331
VoiceRelay core tests, 166 app tests, pinned patch checks and packaging/static
regressions. Existing private-document/native opt-ins remain reported skips.
Evidence is `.local/validation/full-EB8A4A13-7243-4038-9C97-B2E0E7854A74/`.
Native short checks passed all 18 new presets, ten Qwen languages and a synthetic
Chatterbox reference. The original 29 sample files/manifest records are unchanged;
18 production-path English samples bring the catalog to 47. Native receipts are
under `.local/multi-model-implementation/`.

Debug and Release workspace builds, both app Archives and all six bundle audits
pass for the coordinated working tree based on `c10135f`. Evidence and isolated
ad-hoc engineering candidates are in
`.local/validation/release-CF376C4F-5242-41A5-8105-B4247F18C718/`.
Each archive contains `Products/Applications/<app>.app`; no installed app was
replaced or launched. The final Libro preview fix stops recorded samples as well
as live previews when language/delivery settings change. The standalone benchmark
passes 26 isolated tests and rebuilds with the raw Chatterbox PCM policy.

Offline preparation and multi-paragraph narration pass through both archived
helpers for Ryan, Chatterbox default and leah. Packaged contention confirms
interactive Qwen precedes waiting background Orpheus, at most one helper is
resident, and waiting cancellation publishes no audio. Logs, prepared plans,
worker hashes and synthetic recordings are in
`.local/multi-model-implementation/native-packaged-*`; the aggregate
`summary.json` records all gates. These bounded passages do not establish
hour-long memory stability or linguistic/listening quality.

Large helpers are reaped between utterances under the existing admission lease;
reload and hash-validation overhead exceeds warm benchmark-call costs. Chatterbox
now preserves raw vocoder PCM by disabling inherited SDK normalization/fade;
original benchmark recordings retain their old processing and bytes. See the
[integration record](MULTI_MODEL_TTS_IMPLEMENTATION_PLAN.md) for design and evidence.
Long-form linguistic quality, GUI/accessibility, actual documents, normal-signed
installed apps and live delivery/player checks remain operator-owned.

## Standalone TTS model comparison

On October 27 the operator reported Qwen3-TTS 1.7B / Ryan as the top bracket
choice, Chatterbox Turbo / default as runner-up, and Kokoro / Heart plus Orpheus
3B / leah as contenders. The [shared integration record](MULTI_MODEL_TTS_IMPLEMENTATION_PLAN.md)
covers all supported preset voices of the selected checkpoints, shared setup/UI,
native adapters, resource admission and both app workflows. The implementation
is described below. This records the supplied ranking without inventing or importing
canonical bracket votes; held-out and long-form listening remain open.

October 24–25 implementation adds the [Swift benchmark utility](../tools/TTSBenchmark/README.md),
independent of either app. It explicitly prepares pinned model assets, supervises
serial offline workers with time/memory bounds, preserves native-rate audio and
records timings, output hashes and durable attempts. A resumable blind model/voice
bracket precedes separate held-out and long-form finalist confirmation.
Cold/warm loads and product-reference variants are timing evidence, not additional
listening entrants. These October 24–25 observations precede the October 27
product integration; the original benchmark artifacts remain unchanged.

All 19 isolated benchmark tests passed. The full project fixture gate, Debug and
Release workspace builds and four bundle audits also passed in a separate
validation directory; no operator app was installed or launched. Command-local
selection of the installed Metal toolchain resolved compiler discovery without
changing project pins or deployment targets.

The M2 Max/32 GiB comparison produced 224 recordings from 12 direct narrator
profiles plus two accepted-product references. An initial zero-audio Kokoro Emma
region mismatch was fixed, tested and rerun separately; the derived report keeps
the original failure, source receipts and both builds' evidence. All WAV hashes,
12 unique bracket entrants, empty preference history and page audio links were
verified. Fish S2 Pro remains blocked for a licensed reference clip/transcript.
The [design/evidence record](TTS_MODEL_BENCHMARK_PLAN.md) identifies local reports
and measurement limits. No operator ranking was recorded at that benchmark run's
creation. The later reported ranking is recorded above; operator
[M01](OPERATOR_VALIDATION.md#model-evaluation-developer-utility) still requires
finalist held-out/long-form acceptance. New product model support remains planned.

The October 25 follow-up replaces per-choice CLI entry with a server-free local
HTML/JavaScript scoring app. Anonymous labels and hashed audio paths conceal names;
the separate identity file is selected only for an explicit final reveal. Browser
storage, JSON backup/restore, notes and revisions preserve choices. A validated
one-time export import connects them to the existing Swift finalist workflow.
The JavaScript tournament is checked against the Swift engine; local-file browser
inspection is blocked by the automation tool, so visual/audio/file-permission
acceptance stays with the operator.
The standalone Release build and all 26 model-free benchmark tests pass, including browser-state save/reload,
stale-tab protection, backup fallbacks, anonymous exports, revision replay and
cross-language tournament fixtures for odd/even fields, rejected pairs and final
resets. Scoring fixtures use JavaScriptCore. A synthetic, in-memory Apple WebKit
fixture additionally verifies initialization, aligned audio/buttons/notes, minimum
control heights and no horizontal overflow at 360, 744 and 1024 pixels. It does not
establish actual Safari playback or local-file permission acceptance.

The Safari layout follow-up gives player cards and the notes/decision panel shared
spacing and responsive grids. The source template is now `bracket-template.html`
to distinguish it from the generated listening page. A startup notice identifies
an uninitialized page and scoring controls stay hidden until initialization.
Opening the template directly cannot load styling, scoring or audio sources;
the generated run-folder page is required. Regeneration verified unchanged
canonical choices, run identity, aliases and progress storage key, plus all 24
anonymous audio hashes. The project quick gate and documentation checks also pass.

## VoiceRelay menu-bar clicks

The menu-bar item now hosts the existing SwiftUI menu in a native status-item
popover with animations disabled for immediate presentation. Left- and right-click
share one button action; Escape/outside-click use
native transient-popover dismissal. Window/Settings actions retain their SwiftUI
scene actions and close the popover first. Input and focus acceptance remains
part of operator case V02.
The menu fits command labels at the selected text size; status/progress wrap
within that width, and keyboard focus effects stay hidden until Tab is pressed.
The October 23 follow-up adds 25% horizontal room, a larger SF Symbol
and Copy Podcast URL. The final symbol correction restores the standard square
slot and doubles the symbol's configured point size instead of its image canvas.
Shared citation controls now sit
beside the other narration options without a nested group box. The authored
default cover, runtime lookup, Xcode resource and bundle audit now use JPEG.
The original menu host passed all VoiceRelay core/app fixtures and Release app
compilation. October 23 polish validation passed 56 selected core tests, 23 selected
app tests and the shared narration Settings composition test. Menu checks include
80%/100%/200% sizing, 25% extra width, changing status, both kinds of progress and
copying the configured feed URL to an isolated clipboard. Debug and Release
workspace builds and all four bundle audits passed, including exact JPEG resource
bytes. The shared test initially encountered a stale Metal compiler mount in build
metadata; regenerating that metadata resolved it without source or pin changes.

Ad-hoc validation candidates for the `e0455a6` working tree with these uncommitted
changes are under `.build/MenuArtworkValidation-20261023/Build/Products/{Debug,Release}/`.
Neither app was installed or launched. These candidates predate the final symbol
configuration correction; rebuild current source for V02. The older title-recovery products below
predate the menu changes; V02 and V12 remain operator acceptance.
A local converter comparison produced a 223,515-byte JPEG from the previous PNG
and a 199,660-byte JPEG from the replacement, both 1700×1700. Original PNG size
alone does not explain missing player artwork; public access and Overcast display
remain unverified. Existing saved cover choices are preserved.

## VoiceRelay article title recovery

October 23 implementation: new asynchronous intake checks title quality and treats
embedded titles matching either PDF filename as weak. Useful Reading List titles
and reliable opening headlines take precedence over those fallbacks. Optional
on-device title generation is off by default and uses bounded opening text through
the shared inference lease. The chosen title/provenance persists with approved
text; All Articles retains a local display title without modifying Safari. Queued
previews use saved source text, and unattempted queued articles support Edit Title.
Started work, existing snapshots and published recordings are not automatically
retitled. See [source handling](../VoiceRelay/docs/SOURCE_REVIEW.md#title-recovery).
Automated evidence includes a passed full fixture gate, final focused title/source/PDF
regressions, Debug and Release builds of both apps, and all four bundle audits.
The engineering products are under `.build/TitleRecoveryValidation-20261023`;
they do not replace the operator's selected app. Real-document title quality,
Settings and contextual editing remain [operator checks](OPERATOR_VALIDATION.md#voicerelay).

## Monorepo migration

The app source histories are imported under `Libro/` and `VoiceRelay/`. No
submodules or nested app repositories are required. Source paths, package identities,
build graphs and runtime settings retain their existing layout. Setup prepares
pinned dependencies; it no longer clones applications. Health and validation
record one root revision, with strict health requiring a clean working tree.

Original Git metadata and import maps are retained in ignored local migration
storage. Historical private validation records, document excerpts, local signing
configuration, obsolete generated icon output and personal home paths are excluded
from the imported history. Product artwork, license notices and the maintained
synthetic voice samples remain included. The requested GitHub origin is configured;
the initial source publication was subsequently performed manually. Source
publication does not imply CI activation or binary distribution.

## Native queue controls and compact status

Libro uses native circular SwiftUI controls for Start/Pause/Resume, Skip and Stop,
with corresponding menu commands. Stop and Skip require confirmation. Pause keeps
partial audio and releases inference admission at a safe boundary. Queue dragging
preserves selected-row order and the current/next-batch partition. Destination,
readiness and queue status share the bottom bar; issue messages open diagnostics.
Existing completed audio and late-arriving queue items retain publication protection.

## EPUB queue and existing outputs

Bounded normalization accepts unpacked EPUB folders through selection, drop and
recursive scans without repacking source files. Linked/unsafe resources and
malformed packages fail explicitly. Finished sources can be queued again; existing
outputs are reviewed through Overwrite Existing, Skip Existing and Cancel before
speech begins. Replacement permission is scoped to the captured batch.

## Prose insets and equation flow

The shared `scientific-text-2` projection preserves paragraph order in prose-heavy
tables and places supported OCR insets relative to the page body. Complex equations
receive one original-text reference per document after column reconstruction.
Every region retains its source range and page. Recognized compatible extraction
and acoustic-policy aliases preserve identical completed requests.

## Scientific equations and tables

Simple verified linear notation uses bounded speech rules. Fragmented or uncertain
formulas receive source-reference cues, retaining original text and mappings.
Advanced mathematical speech remains deferred. Explicit table cells receive labels;
ragged grids and uncertain OCR get conservative cues. Optional bounded native OCR
can recover image-table text while preserving the native page. Native extraction,
MathML handling and complex layout still have limits. See
[scientific narration](SCIENTIFIC_NARRATION.md) and
[academic PDF findings](ACADEMIC_PDF_EVALUATION.md).

## Citation choices and PDF narration reconstruction

Academic citation controls follow Footnotes. Inline and endnote stripping default
off and preserve existing saved preferences. Confirmed reference structures can
support omission; uncertain prose, dates, arrays and explanatory notes remain.
PDF margin cleanup requires repeated isolated geometry; supported column bands
reconstruct only the spoken projection. Original text and UTF-16 mappings remain.
See [narration cleanup](DOCUMENT_CLEANUP.md).

## Shared pronunciation Settings presentation

Both apps use shared PronunciationUI and AppPresentation components. The editor
uses the requested width and a rounded settings-section background. Scope guidance
appears under an information control. Preview dependencies are supplied by the apps;
editing behavior and existing dictionary persistence remain shared.

## VoiceRelay bundled default podcast cover

VoiceRelay bundles its authored cover image as the initial podcast artwork.
Existing custom artwork and explicit user changes retain precedence. Packaging
checks compare the bundled resource to the maintained source image.

## VoiceRelay background credentials and optional login startup

Background credential access avoids interactive Keychain prompts; explicit settings
actions handle credential changes. Rebuilding or changing signing identities can
change Keychain authorization independently of application logic. Optional login
startup uses the platform service API. The October 29 startup revision above changes
fresh configurations to a one-time default-on request with the control only in
General Settings; existing choices remain intact. Keychain behavior, system approval and reboot/login
acceptance remain operator-owned.

## Libro Document settings

Document examples are collapsed by default behind disclosure controls. Shared
Settings sections own common narration and pronunciation presentation; app-specific
preferences and workflows stay with each app.

## Libro progressive PDF previews

Initial PDF analysis processes the first five percent rounded up to complete pages,
capped at five pages and at least one.
Narration/source previews can populate before full analysis finishes; background
progress and cancellation retain document/session identity. The interface labels
this work as text analysis. Preview sizing and controls avoid compressed text layout.
Actual-document responsiveness and visual acceptance remain operator-owned.

## Automatic Libro document covers — automated checks complete

Assigned or detected cover artwork is visible beside library titles. Native cover
discovery preserves explicit choices and intentional removal. EPUB/PDF cover paths
use existing bounded intake and artwork handling rather than replacing source files.

## Experimental PDF printed-word joining

Printed-word joining is opt-in and defaults off. It uses local line geometry,
structural exclusions and platform dictionary evidence; ambiguous cases abstain.
Discretionary soft-hyphen cleanup remains separate. Original source text and mappings
are preserved. The Readium adaptation's BSD notice and provenance are retained.
See [text processing](TEXT_PROCESSING_IMPROVEMENT_PLAN.md) and
[provenance](PROVENANCE.md).

## Accepted policies and engineering gates

The existing operator-accepted Kokoro baseline remains Heart at 1.0× with actual
phoneme packing and structural pauses. Saved speeds, captured jobs and Soprano's
frontend remain compatible. Audio is never normalized, levelled, limited or given
gain. MLX stays helper-only, with one worker per app and shared admission priority.

The October 20 monorepo validation established the migration baseline:
full synthetic fixtures, Debug and Release workspace builds and all four bundle
audits passed. Those audits include
ad-hoc signatures and offline packaged Metal probes. Migration-specific results
are recorded in [the migration record](MONOREPO_MIGRATION.md).
Build/fixture evidence does not establish GUI, listening, private-document,
Keychain, live-server or distribution acceptance. The consolidated
[operator checklist](OPERATOR_VALIDATION.md) retains those gates.

## Documentation review — October 21

Root and app entry points now distinguish users, power users, developers and agents.
The [narration guide](NARRATION_GUIDE.md), [documentation index](README.md) and
[documentation policy](DOCUMENTATION.md) explain current controls, guide ownership,
command scopes and historical records. UI labels/defaults and setup were checked
against the current source. No application behavior, dependency pin, audio policy,
manual acceptance or release state changes as part of this review.

Documentation validation passed the quick tier (static checks and 78 isolated
development-tool assertions), recorded in
`.local/validation/quick-E2354F2A-29D0-4FB6-B48D-789DBF3652EA/summary.json`.
Nested package/build/icon/provenance guide links were checked separately. These
results validate documentation/tooling, not a new application or live-service run.
