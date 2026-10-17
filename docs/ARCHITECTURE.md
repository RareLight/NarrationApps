# Shared architecture

Current contract, October 15, 2026. Product boundaries and package installation
are in [PACKAGE_BOUNDARIES.md](PACKAGE_BOUNDARIES.md); the app repositories own
GUI/workflow, preferences, source authorization and app-specific persistence.

## Processing boundaries

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

New Kokoro settings use `af_heart` at 1.0×. The accepted preparation policy retains
its evidence identifier `phoneme-200-pauses-candidate-1`; “candidate” is an internal
version string, not a user quality setting. It targets 200 actual supported phoneme
scalars, prefers sentence/clause boundaries and never exceeds the 510-token model
limit or cuts an indivisible word's phonemes. Source windows are independently
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
Soprano retains its native frontend and numeric forms. Common `text-flow-1` adds
mapped discretionary hyphens and source-preserving document flow to both engines;
acoustic packing/pause/audio policy is unchanged. Underlying raw G2P
and contextual homographs retain the limitations in the
[research record](TEXT_NORMALIZATION_RESEARCH.md). Phoneme/reference equality is
not operator listening acceptance.

Optional PDFTextLayout values retain bounded native line evidence; optional
NarrationOmission records retain source spans and omission reasons. Known margin
labels/folios and conservative page continuations use that evidence once before
G2P; uncertain geometry/columns and old artifacts abstain. Optional layout budgets
never discard prose or bypass mandatory intake limits.

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

Each application embeds its own private signed helper and Metal library. MLX is
linked into NativeSpeechEngine in that helper, never the GUI. ProcessingPipeline
supervises one helper/model session per app and reuses compatible sessions.

The per-user inference lease also coordinates heavy OCR/image-description work.
Pending interactive Libro work takes priority over background VoiceRelay at safe
boundaries. In-flight GPU calls are not interrupted for priority. Cached models
can remain resident while waiting; one active inference lease is not one total
resident process. Legacy lock naming is retained where required for compatibility.

MLX cache/working thresholds and sampled host process-footprint limits provide
bounded failure handling, not a hard whole-system memory ceiling. Failure/cancel
joins and reaps owned processes, removes owned staging and preserves finished
outputs; there is no automatic multi-worker fallback/replay.

Control IPC remains bounded/versioned. Large preparation payloads use private,
exclusively owned spool files with size/count/digest/path/link validation. No
whole-document MLX tensor or global text cache is introduced.

## Audio

The structural target gaps are continuation 0, sentence 0.12 s, paragraph 0.28 s,
heading 0.45 s and footnote transition 0.20 s. Only exactly zero edge frames count
toward these targets. Model near-silence and all speech samples remain untouched;
there is no leading/trailing gap, silence trimming, gain or crossfade.
VoiceRelay's saved nonzero artifact gap is a minimum target, not a second blanket
gap; an explicit zero disables inserted gaps. Validate that preference in the GUI.

WAV preserves native Float32 samples/rates: Kokoro 24 kHz, Soprano 32 kHz. Podcast
and bundled sample AAC-LC use mono 64 kbps/24 kHz with native resampling when needed.
Libro's direct native-rate AAC exports retain the model rate; do not describe all
Soprano exports as 24 kHz. MP3 uses the prepared native LAME library with ReplayGain
disabled. Lossy formats are not bit-identical to WAV. There is no normalization,
volume leveling, dynamic compression, limiter or automatic gain.

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
