# Shared architecture

Current contract, October 15, 2026. Product boundaries and package installation
are in [PACKAGE_BOUNDARIES.md](PACKAGE_BOUNDARIES.md); the app repositories own
GUI/workflow, preferences, source authorization and app-specific persistence.

## Processing boundaries

`document intake → semantic blocks → captured spelling rules → spoken projection
→ bounded native G2P → immutable prepared utterances → synthesis → assembly → encoding`

NarrationCore retains original blocks, page/source origin and spoken ranges.
Omissions and image-caption deduplication are visible in previews; ordinary prose
is preserved. User rules apply once, before final phonemization. Prepared plans
carry settings, acoustic identity, utterance fingerprints and frontend/resource/
packing/assembly provenance. Display/preparation counts are provisional until the
native frontend freezes acoustic utterances.

DocumentProcessing uses Foundation, PDFKit, Vision RecognizeDocumentsRequest,
Foundation Models and pinned HTML extraction. See [document handling](DOCUMENT_PROCESSING.md).
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

The current frontend still mishandles some combined numeric-unit forms,
temperatures and contextual homographs. Supported phonemes do not prove semantic
pronunciation correctness. The researched next increment is documented in
[TEXT_NORMALIZATION_RESEARCH.md](TEXT_NORMALIZATION_RESEARCH.md); it is not enabled.

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

## Recovery and shared UI

Semantic/acoustic and encoding identities are separate. Unfinished incompatible
plans are safely reprepared through the owning app; already placed/published,
integrity-confirmed recordings remain unchanged. VoiceRelay owns durable SQLite
checkpoints/publication; Libro owns batch destinations and replacement decisions.

AppPresentation is independent of narration and owns typography, text-size
commands, pane navigation/help/notices and Appearance controls. NarrationUI owns
speech controls; apps retain pane inventory, preferences and lifecycle. See
[Settings ownership](SETTINGS_ALIGNMENT.md) and [sample generation](VOICE_SAMPLES.md).
