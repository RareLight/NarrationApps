# Shared architecture

Current contract reviewed November 4, 2026. Product boundaries and package installation
are in [PACKAGE_BOUNDARIES.md](PACKAGE_BOUNDARIES.md); the app directories own
GUI/workflow, preferences, source authorization and app-specific persistence.

## Processing boundaries

VoiceRelay's disabled-by-default VoiceServer accepts only authenticated model/voice
metadata and speech routes through SwiftNIO 2.95.0. It captures existing selections
and runs bounded FIFO jobs through the app's same coordinator. The response owns
one sequential MP3/PCM encoder or complete Float32 WAV writer; private response
scratch is outside podcast/history/review storage. Synchronous bounded socket
writes run only on admitted CPU queues, never UI/event-loop/GPU callbacks. A
directory ownership lock survives parent failure until actual helper/writer exit;
orphan cleanup requires the versioned marker and an exclusive lock. Settings owns
Keychain grants and explicit local-interface bindings. See the
[VoiceServer guide](../VoiceRelay/docs/VOICESERVER.md) for protocol, limits and lifecycle.

`document intake → semantic blocks → captured spelling rules → mapped spoken forms
→ spoken projection → bounded native G2P → immutable prepared utterances → synthesis → assembly → encoding`

NarrationCore retains original blocks, page/source origin, optional EPUB resource
paths and spoken ranges. Resource paths describe archive provenance; they do not
redefine spoken UTF-16 offsets or the original file bytes.
Omissions and image-caption deduplication are visible in previews; ordinary prose
is preserved. User rules apply once, before final phonemization. Prepared plans
carry settings, acoustic identity, utterance fingerprints and frontend/resource/
packing/assembly provenance. Display/preparation counts are provisional until the
native frontend freezes acoustic utterances.

DocumentProcessing uses Foundation, PDFKit, Vision RecognizeDocumentsRequest,
Foundation Models, ZIPFoundation for bounded EPUB container reads, and pinned HTML
extraction. Foundation decodes legacy text with an optional per-input override;
source files are never rewritten. See [document handling](DOCUMENT_PROCESSING.md).
Pronunciation owns shared dictionary storage; PronunciationUI owns editing and
on-demand preview lifecycle. See [pronunciation](PRONUNCIATION.md).

## Kokoro and Soprano

New Kokoro settings use `af_heart` at 1.0×. Mandatory semantic packing uses
`phoneme-semantic-compounds-2`, replacing the October 15 packing policy after
operator listening. It targets 200 actual supported phoneme scalars, may grow
toward 300 to complete a phrase, prefers sentence/clause boundaries and never
exceeds the 510-token model limit or cuts an indivisible word/compound's phonemes.
Aligned letter-to-letter compound hyphens become word-separator phones rather
than dash pauses; original text/mappings stay intact. Source windows are independently
bounded to 1,000 scalars. Voice style uses the verified length-minus-one row.

Misaki uses pinned regional US/GB resources with no silent British-to-US fallback.
Foundation number spelling and recorded numeric/currency port fixes are active.
Unsupported vocabulary, alignment or over-limit input fails explicitly rather
than truncating text. Soprano retains its native text frontend and planner.
Historical policies exist for developer comparison and compatibility only.

Kokoro's versioned `spoken-forms-2-en_US/en_GB` projection corrects explicit
capital-A labels (Package A, Plan A) and expands `kg`,
degree-Celsius/Fahrenheit quantities and valid 12-hour AM/PM times before its native
frontend. Foundation MeasurementFormatter retains the provided unit and numeric
precision; the frontend still owns number/currency spelling. Explicit negative
quantities say “minus”; `9:05 pm` becomes `9 oh 5 p.m.`, and `12:00 pm` becomes
`12 p.m.`. URLs, code, paths, equations, identifiers, ambiguous forms and captured
user replacements are protected. Native Markdown/HTML/EPUB retain an optional
inline-code flag: affected paragraphs stay unchanged. Legacy markup with neither
that metadata nor authored/OCR provenance abstains; no implicit refetch occurs.
Unverifiable source alternatives also abstain.
Before the native frontends, common `scientific-text-2` reads verified linear PDF
equations and prose table entries in their local flow. Complex display math gets
one original-text reference notice per document, retaining every omitted range.
Numeric tables require reliable value associations. Unrecoverable table
relationships get explicit source-reference cues with retained original text.
Native text and bounded targeted image-table OCR keep distinct provenance. See
[scientific narration](SCIENTIFIC_NARRATION.md) for recognition/grammar limits.
Soprano retains its native frontend and numeric forms. Common `text-flow-1` adds
mapped discretionary hyphens and source-preserving document flow to both engines;
acoustic packing/pause/audio policy is unchanged. Underlying raw G2P
and contextual homographs retain the limitations in the
[research record](TEXT_NORMALIZATION_RESEARCH.md). Phoneme/reference equality is
not operator listening acceptance.

Optional PDFTextLayout values retain bounded native line evidence; optional
NarrationOmission records retain source spans and omission reasons. Recurring
isolated margin labels/folios, supported two-column bands and conservative page
continuations use that evidence before G2P. Captured citation choices add optional
mapped reference omissions; dictionary checks constrain fragmented-word repairs.
Uncertain geometry/columns and old artifacts abstain. Optional layout budgets
never discard prose or bypass mandatory intake limits.

Libro's interactive PDF preview can receive awaited, provisional extraction
prefixes: rounded-up 5% capped at five pages, then doubling page counts from one
pass. Narration is replanned off the UI actor with one captured settings/dictionary
snapshot, before the final optional image pass. Only the preview consumes partial
documents; generation and VoiceRelay retain complete extraction by default. The
live sheet marks provisional results and owns cancellation through the existing
intake task. Mandatory extraction budgets are cumulative, never reset per prefix.

Captured NarrationOptions can enable an off-by-default experimental Readium-style
printed-word joiner before pronunciation/G2P for either engine. Verified digital
PDF line/page seams supply mapped hyphen/whitespace omissions; structural exclusions
and four-page/200-fragment caps retain unjoinable boundaries. English dictionary evidence preserves recognized compound hyphens and permits
verified joined spellings; unknown alternatives remain unchanged. Supported
within-column evidence can be used on multi-column pages. Remaining layout/spelling
uncertainty is disclosed in the control and preview notices. Original
source stays intact; no Readium runtime, second parser or model is introduced.

Optional ProjectionMapping runs connect block-local extracted UTF-16 coordinates
to chunk-local spoken coordinates; prepared ranges remain spoken coordinates.
Whitespace, canonical Unicode, known note-marker removal, user replacements and
automatic expansions compose without rewriting source blocks. Generated/unaligned
cues have no fabricated source range. Old artifacts decode absent maps as nil.
Unchanged runs coalesce; no-change inputs carry no new mapping payload. Candidates,
edits and mappings are bounded at 100,000, with an 8× + 256 per-stage expansion
ceiling. Policy/locale enter semantic/preparation identity; unchanged text keeps
compatible acoustic fingerprints. Host maps survive windowing/preparation and
checkpoints, but are stripped from the helper's 64 KiB control messages.

## Helpers, admission and memory

The production VoiceServer coordinator also owns `SpeechHostAdmission`. App-owned
document tasks explicitly carry that context across detached boundaries; existing
Vision/Foundation Models lease calls then join API > Libro > Podcasts admission
and retain current/legacy exclusion through actual completion. Platform calls
already submitted yield cooperatively. Host demand uses a distinct instance so
idle same-app speech residency cannot deadlock its grant. Setup uses a real
initialize-only coordinated unit; pronunciation/review sessions capture the same
worker owner. Both apps have optional constructor and joined Quit bindings, but
injected construction still defaults to nil; production supplies the owner. Its maintenance gate refuses new jobs,
stops accepted API work, parks background CPU work, reaps its helper and joins
started platform leases before installation/deletion. Only still-eligible
background jobs resume afterward. Quit joins the actual maintenance operation.
Deletion retains the independent model-storage exclusion; no app kills another
app's helper.

Opt-in CPU demand ranks source integrity checks, narration planning, PCM journal
reads/writes, validation, encoding and publication without authorizing a model
host. Each synchronous CPU operation owns a separate utility queue and cooperative
checkpoints; a parked podcast encoder cannot block a live response encoder or the
UI. Same-app CPU finalization does not serialize the next same-rank speech unit.
Published recordings remain published if a later recovery receipt fails.
`NarrationPreparationWork` carries an optional synchronous CPU executor through
async readers and detached app tasks. Document decoding, per-page PDF processing,
EPUB chapter extraction, preview planning and review PCM/hash/diagnostic writes use
that executor; Core and audio checkpoints share the same admitted operation.
PDFKit objects stay exclusively owned across sequential CPU units. Actual platform
OCR, title/image generation and recognition remain outside CPU units and own their
inference leases. Their active-work budgets exclude admission waits. Already-issued
platform calls finish cooperatively.

Optional review writes serialize and join before session replacement/close. A
cancelled repair removes only its newly owned take, after joining cleanup; original
reviews and recordings remain intact. Article admissions cancel/join their real
preparation tasks. New snapshot planning/hash/encoding precedes the writer
transaction, which rechecks exact saved snapshot bytes and captured chunk limits
before committing. No CPU admission wait holds that writer transaction.
Queue-title preparation and chunk-count planning now run through CPU admission;
each result rechecks the saved row, snapshot and episode after actor reentry.
Title preparation holds no database writer while waiting, and stale planning
failures cannot mark a changed row failed. Libro intake enumeration and automatic,
manual and retained cover operations also use admitted CPU work, with cooperative
checkpoints between filesystem entries and image operations. Already-issued
File Provider, PDF rendering and ImageIO calls finish cooperatively. Remaining
legacy metadata reads and recovery/file-access/retention still gate activation.

Payload-free macOS notification wakeups supplement periodic safety checks; only
the locked demand registry grants work. Transient waiting projections reject late
source/run events and leave progress counts, errors and manual Pause/Stop intact.
Explicit recovery/file-access UI and retention/repair still gate activation.

`AudioStreamEncoder` owns one response's resampler and codec, accepts bounded
finite mono Float32 frames and emits sequential MP3 or 24 kHz signed 16-bit little-
endian PCM. It never seeks or concatenates independently encoded fragments. MP3
uses the existing pinned native LAME at unity scale with ReplayGain disabled;
its non-seeking mode omits the rewritable Xing frame. Existing file exports retain
their gapless/seek metadata. PCM rejects unrepresentable levels instead of clipping
or applying gain. Disconnect, output bounds and codec errors terminate the encoder
without a flush/replay. HTTP backpressure, deadlines and request routing remain
separate, unimplemented work. Both app bundles embed/sign the same prepared codec
and include the shared notices.

Each application embeds its own private signed helper and Metal library. MLX is
linked into NativeSpeechEngine in that helper, never the GUI. ProcessingPipeline
supervises one helper/model session per app and reuses compatible sessions.

Cold normal-serving narration sessions initialize storage without a helper. Text
preparation then starts only the model's frontend: the same pinned local tokenizer
for Qwen, Chatterbox and Orpheus, a scalar budget for Soprano, or Misaki plus the
pinned Kokoro phoneme vocabulary. No acoustic weights are needed. First-use Qwen
conversion reuses the pinned SDK's JSON converter, with generated sidecars
confined to the validated private overlay. CPU tokenizers
remain resident across preparation windows and do not acquire inference admission.
Kokoro's neural G2P fallback remains serialized under admission; a paused checkpoint
or pending interactive demand unloads it before releasing admission, keeping the
helper PID. Completion also releases this neural frontend. At first generation,
the same helper drops frontend resources and loads the speech model under the
inference lease. Already-resident compatible speech models can still be reused;
large speech helpers retain their existing per-utterance reap policy. Standalone
setup validation still initializes the complete speech model.

Libro captures a separate maximum CPU-worker preference per batch (Automatic uses
available cores, capped at 32). Only deterministic tokenizer counts run in joined,
bounded concurrent batches; linguistic taggers and generation stay serial. Prefix
scan order, segmentation boundaries, source mappings and acoustic identity remain
unchanged. Stop joins the owned CPU tasks/helper before scratch cleanup. Recovery
retains the captured limit; older manifests without it restore the serial default.
Coordinated cold preparation starts a lightweight frontend. Speech promotion
acquires residency and loads the model in that same helper; compatible live
demand can take over promotion before lower-priority generation starts.

The per-user inference lease also coordinates heavy OCR/image-description work.
The processing order is API > Libro > podcasts. Streaming live demand cancels an
unfinished lower-priority unit through its owned producer, joins GPU drain/reset
and resumes from verified checkpoints. Complete-file API and Libro-to-podcast
handoffs yield at safe boundaries. Compatible same-app jobs reuse weights;
cross-app handoffs unload the old owner before the next loads. Older builds retain
the compatibility locks and need restarting for the new coordinated behavior.

MLX cache/working thresholds and sampled host process-footprint limits provide
bounded failure handling, not a hard whole-system memory ceiling. Failure/cancel
joins and reaps owned processes, removes owned staging and preserves finished
outputs; there is no automatic multi-worker fallback/replay.

Control IPC remains bounded/versioned. Large preparation payloads use private,
exclusively owned spool files with size/count/digest/path/link validation. No
whole-document MLX tensor or global text cache is introduced.

VoiceServer feasibility retains an explicit `--handoff-probe` helper mode.
Production coordinated serving uses its admission-required `--coordinated-serve`
variant. The versioned control loop owns one
cancellable producer and joins it before GPU drain/reset/ready. One-frame credits
bound PCM transfer, including cancellation while the consumer stalls. The helper
holds existing current/legacy inference exclusion and model-storage protection
from initialization through unload; parent EOF joins work before release. This
probe mode continues to support isolated native reuse/first-audio measurements;
production admission uses the three-rank scheduler described above.
The recorded Soprano producer-ownership patch joins its internal token task in
both generation consumers; cancelling an AsyncStream iterator alone is not a
quiescence guarantee. The Qwen probe uses a maintained synchronous throwing
callback on that same owned task; adapter cleanup resets the incremental decoder
on completion or cancellation. A versioned live-only first-sentence policy retains
source/pronunciation mappings and leaves ordinary narration packing unchanged.
Private coordinated/probe wire version 7 exposes lease-wait/acquire, unload,
frontend resource state and controlled loaded-
initialization admission events. Initialization is cancellable/joined independently
of its control reader. Production IPC is version 4: frontend-only initialization,
resource-release acknowledgement and same-process speech promotion fail closed
with an incompatible helper. Lifecycle events operate alongside the durable
admission/residency protocol. Other public
incremental streams with hidden producers remain unused.
The opt-in Qwen decoder correction now passes direct/stream numerical PCM parity,
coverage and reset reuse. The initial planned API path still uses complete bounded
Qwen utterances; the raw callback stays probe-only pending continuity/listening
acceptance. Warm cancellation timings also do not define first-use
or cross-app deadlines. The measured transfer retains unload-before-load and does
not introduce a shared model host.
Shared `SpeechWorkAdmission` and `SpeechAttemptFence` provide bounded three-rank
metadata, kernel ticket liveness, FIFO live demand, registration/final-launch and
commit fences, plus job/attempt epochs and verified-index cursors. A nonblocking
compatibility-lock handshake never waits for another owner under the registration
gate. Hosts retain demand tickets; helpers must retain the returned residency
lease until GPU drain/unload. Final commits use the shared decision gate and the
local attempt fence, with validation/hashing outside both. Production factories
in both apps provide `SpeechWorkCoordinator`, which owns a reusable helper via
`--coordinated-serve`, which requires private admission and rechecks it at each
preparation/generation launch. `WorkerConfiguration.workCoordinator` is nil by
default for injected/legacy consumers. Production native sessions retain their render/writer while a unit retries
after priority suspension. A private `SpeechRenderJournal` records captured plans
and verified PCM using short fenced descriptor commits; it can reconstruct an
unfinished output without persisting encoder state. Both apps join lifecycle
cleanup and use notification wakeups. VoiceRelay
persistence stages validation/JSON/SQLite writer acquisition before an epoch-fenced
COMMIT, with automatic rejected-result retry inside the same run. Receipts contain
no PCM and never serialize into saved checkpoints. `LibroBatchRecovery`
captures ordered sources, settings, dictionary/cover data and destination/consent
proofs, then reuses verified prepared plans/PCM through the normal queue/render
path. Libro's Interrupted Batches UI restores original file access and validates
captured settings without starting work; Resume is explicit. Interrupted records
remain until resumed/discarded. Verified-complete records are cleaned only after
joined work; damaged/unavailable records are retained. Fixture
coverage is separate from installed-assets,
GUI, listening and long-duration acceptance.
See [the checklist](VOICESERVER_IMPLEMENTATION_CHECKLIST.md) for evidence and
[development gates](DEVELOPMENT.md#additional-model-checks) for explicit invocation.

## Shared model cache and deletion

The pinned HuggingFace `HubCache` resolves the standard shared location for new
installations. An app-specific storage override is retained. Existing workspace
layouts continue to work; a versioned marker identifies new Hub-root layouts.
Hub owns blobs, snapshots, metadata and transfer locks. Private runtime overlays
use links to immutable, hash-validated blobs and own generated tokenizer files.
They never rewrite a shared snapshot. Invalid shared blobs fail validation rather
than being silently quarantined on behalf of other applications.

`ModelStorageLease` holds shared access throughout a speech session or explicit
installation, including admission waits and warm idle workers. Confirmed model
deletion requires exclusive nonblocking access and validates all removal paths
before mutation. It removes only the known primary repository and owned copies;
imported sources, references, audio and unrelated repositories remain intact.
External applications do not participate in this app-to-app lease. NativeSpeech
owns the cache/inventory operations; NarrationUI owns the common settings list
and app-joined deletion task. File enumeration and deletion run off the UI actor.

## Additional native models

Qwen3-TTS 1.7B CustomVoice 8-bit, Chatterbox Turbo FP16 and Orpheus 3B BF16
use the same shared catalog, native-text preparation, private helpers and assembly.
All nine Qwen presets, eight Orpheus English presets and Chatterbox default/reference
conditioning are supported. VoiceRelay captures a typed optional model selection;
legacy jobs still resolve to their original Kokoro settings. New frontend/codec/
variant/language/reference/PCM policy identities prevent cross-model checkpoint reuse.
Settings-only selection history is stripped from helper requests and acoustic identity.

The native-text policy retains source mappings and structural boundaries, targets
350 scalars with a 480-scalar window bound, and checks actual input tokenizer counts
inside the helper against a conservative 512-token bound before inference. It requires
clean model EOS; token-cap exhaustion is not successful speech. Qwen's language is
independent of its speaker. English scientific expansion and dictionary word joining
abstain for non-English narration. No source translation or rewrite is introduced.

Model setup acquires pinned auxiliary assets as well as primary weights. Local
SNAC/S3 loaders avoid hidden downloads; generated tokenizer sidecars are validated
against deterministic hashes. Generation checks are offline and fail on incomplete
conditioning. Large models have separate 8/16 GiB footprint guards and 16/24 GiB
minimum-system-memory checks. To serialize residency as well as GPU operations,
a large helper is reaped before releasing admission after each utterance. This
conservative policy adds loading/validation time; old smaller-model reuse remains.
These limits are not a hard whole-machine allocation guarantee.

NativeSpeech owns static model guidance and reference-profile storage; NarrationUI
owns the shared controls/meters. Guidance does not load models or affect acoustic
identities. References are immutable private WAVs, staged with digest verification
inside an owned attempt before helper access. Missing references never fall back
to default conditioning. See [the model guide](MODEL_SELECTION.md).

## Audio

The structural target gaps are continuation 0, sentence 0.12 s, paragraph 0.28 s,
heading 0.45 s and footnote transition 0.20 s. Only exactly zero edge frames count
toward these targets. Model near-silence and all speech samples remain untouched;
there is no leading/trailing gap, silence trimming, gain or crossfade.
VoiceRelay's saved nonzero artifact gap is a minimum target, not a second blanket
gap; an explicit zero disables inserted gaps. Validate that preference in the GUI.

WAV preserves native Float32 samples/rates: Kokoro/Qwen/Chatterbox/Orpheus
24 kHz, Soprano 32 kHz. Podcast
and bundled sample AAC-LC use mono 64 kbps/24 kHz with native resampling when needed.
Libro's direct native-rate AAC exports retain the model rate; do not describe all
Soprano exports as 24 kHz. MP3 uses the prepared native LAME library with ReplayGain
disabled. Lossy formats are not bit-identical to WAV. There is no normalization,
volume leveling, dynamic compression, limiter or automatic gain.

NativeAudio's AAC encoder also returns per-input output-frame intervals, measured
after resampling and actual gap insertion. VoiceRelay uses them with prepared text
for optional default-on WebVTT episode transcripts; this does not alter PCM or add
word alignment/ASR. The app owns transcript persistence, verified delivery, RSS
references and retirement; see [VoiceRelay architecture](../VoiceRelay/docs/ARCHITECTURE.md#publishing-recovery-and-cleanup).

CoverArtwork prepares bounded JPEG derivatives through ImageIO/CoreGraphics.
Book covers preserve aspect ratio and fit the pinned LAME album-art budget;
podcast covers use a separate square/opaque profile. AudioOutput embeds MP3 ID3
art with LAME and M4A/M4B art with native passthrough before the existing atomic
rename. Tagging does not re-encode or level audio. Cover inputs remain host-side;
packaging identity is separate from acoustic preparation. Libro owns per-document
choices; VoiceRelay owns channel-art configuration and verified publication.
Episode artwork remains an independent external publisher URL. See the
[implemented cover/navigation stages](COVER_ART_AND_NAVIGATION_PLAN.md).

## Recovery and shared UI

Semantic/acoustic and encoding identities are separate. Unfinished incompatible
plans are safely reprepared through the owning app; already placed/published,
integrity-confirmed recordings remain unchanged. VoiceRelay owns durable SQLite
checkpoints/publication; Libro owns batch destinations and replacement decisions.
Libro accepts queued documents regardless of existing regular audio outputs.
Explicitly re-adding a finished source queues its existing row again. At Generate
Audio, destinations are checked afresh before a native Overwrite Existing / Skip
Existing / Cancel prompt. Skipped documents are marked in the queue and can be
queued again; cancellation changes neither queue decisions nor audio. Replacement
approval is scoped to files present in that batch snapshot; late arrivals remain
protected by coordinator revalidation and an exclusive atomic rename for
unapproved targets. Selected directory inputs protect their complete canonical
subtree, including unpacked EPUB resources. Direct rendering APIs retain their
owned-output replacement defaults; the queue passes explicit per-job approval.
Whole-batch collision validation happens once at admission, using ancestor-set
membership rather than quadratic prefix scans. Each safety boundary revalidates
the current target against captured bindings and refreshed source/other-output
inode protection; mutable files are not assumed unchanged. This retains linear
live-source checks per boundary without reconstructing every output plan.
Settings and output names are
captured for that batch before asynchronous cover preparation.

Libro persists validated model, voice, applicable controls and per-model choices
in app-owned preferences,
independently of installed model assets. Unsupported/corrupt saved records use
safe in-memory defaults and remain untouched until a valid user change is saved.
The file-drop owner retains provider resolution through cancellation/shutdown,
invalidates stale completions and joins replaced work. Provider cancellation
resumes the waiter once even if a provider ignores cancellation; late callbacks
cannot reintroduce rows. Replaced scanners join their predecessors before native
intake/cover work starts; Quit joins that chain.

Libro's native SwiftUI table owns drag selection and insertion markers. Queue
ordering survives later imports; a running batch can reorder only its waiting
IDs. Current/completed positions, captured membership/settings/destinations and
next-batch membership remain fixed. `BatchQueueControl` supplies cooperative
pause/skip boundaries before native preparation windows, speech chunks and
publication. Pause keeps the current temporary audio and worker, releasing
inference admission while waiting. Resume continues that same item. Confirmed
Skip finishes an in-flight operation, discards the item's temporary audio, reaps
its worker and continues with a fresh session. The publication boundary rejects
late skips of committed items and stale confirmations cannot target the next job.
Stop cancels the batch and leaves unfinished items queued for a later Start.
Injected callers without a work coordinator retain their legacy session behavior.

Native circular glass controls sit to the right of cover editing below the queue
divider, ordered Start/Pause/Resume, Skip, Stop. The first button shows Play when
idle or paused and Pause while running; Stop remains separate. The bottom status
bar groups readiness, queue totals, activity and Save Location with its selectable
path and adjacent Browse button. Queue Actions retains full diagnostics; new
import, destination, setup and generation errors surface in a small popover anchored to that
menu, and status-bar issue messages also open the diagnostics.

AppPresentation is independent of narration and owns typography, text-size
commands, pane navigation/help/notices and Appearance controls. NarrationUI owns
speech controls; apps retain pane inventory, preferences and lifecycle. See
[Settings ownership](SETTINGS_ALIGNMENT.md) and [sample generation](VOICE_SAMPLES.md).

App source organization keeps workflow ownership local. Libro's `LibroApp.swift`
owns scenes/delegate/window restoration; `IntakeModel.swift` retains intake/batch
state and owned tasks. Queue, intake, document preview, Settings, narration controls
and speech setup have separate view files. VoiceRelay retains AppModel state and
lifecycle in `VoiceRelayApp.swift`, with main-actor Sync, speech-setup, health and
event-projection extensions in `AppModel*.swift`. Only the minimum module-local
visibility needed by those extensions is shared; no public API, persistence key
or task/join owner changed. Delivery/DeliveryRead remain app-owned and unchanged.

## Authored navigation and narration choices

SemanticDocument optionally retains bounded outline entries and source destinations.
Content blocks retain source IDs/ancestor anchors and reliable auxiliary/bibliography
roles. EPUB nav/NCX and PDFKit bookmarks supply authored navigation; heading
fallbacks use actual HTML/Markdown structure. Page-only PDF destinations remain
page-only. Generated-image insertion updates outline indices without reordering
prose. UI Contents menus navigate source and never schedule a new speech segment.

NarrationOptions is a shared typed policy with app-owned persistence. Defaults keep
current note placement and auxiliary text. Future Libro batches/new VoiceRelay
queue captures may move notes to the end or omit them, and omit explicitly marked
auxiliary sections. Bibliographies and unclassified prose remain. Whole-block
omissions retain original UTF-16 spans, optional PDF page and visible reasons;
local structural heading deduplication uses the same mechanism. Optional PDF
layout-budget fallback preserves these explicit policy decisions. Source/metadata
upgrades retain compatible unchanged chunk fingerprints and finished recordings.

## Experimental long-form preparation and review

Semantic phrasing is mandatory for every model. Saved planning values decode as
inert compatibility metadata and never change effective preparation; Kokoro selects
its current policy and all other models select native text, regardless of any
requested historical policy. Non-Kokoro narration versions carry
`semantic-boundaries-1`; Kokoro's packing stays versioned in its acoustic policy.
Old policy identifiers remain decodable as artifact history, but new sessions
always select the current policy, including recovery/review regeneration. Incompatible
unfinished work is reprepared; completed recordings and bundled samples remain intact.
Semantic planning uses native helper tokenizer counts for
Qwen/Chatterbox/Orpheus, retaining independent IPC bounds and structural boundary types. Soprano
uses a disclosed scalar budget because its public frontend lacks token counts.
No new default sampling, prompt, residency or waveform policy is enabled.

Pronunciation entries can qualify language, exact document title and model, with
document overrides preceding shared defaults. Legacy aliases are English-scoped.
Trusted Kokoro phone overrides are separate aligned values, not prose markup.
Optional dictionary metadata and captured document titles decode absent in old
artifacts. Optional English spoken forms stay separate from segmentation and
never activate for non-English narration.

ProcessingPipeline owns opt-in private review plans, per-chunk lossless journals,
read-only diagnostic flags, installed-only Apple SpeechAnalyzer checks and explicit
selective repair. Review shares each app's existing joined pronunciation-preview
ownership; no second app helper or automatic replay is introduced. Completed media,
server state and transcript references are never changed by review. Explicit new
WAV exports recompute segment frame intervals from actual PCM and inserted exact
zeros; ASR cannot provide authoritative text or word timestamps. See
[quality behavior and limits](LONGFORM_QUALITY.md) and its
[implementation plan](LONGFORM_QUALITY_IMPLEMENTATION_PLAN.md).
