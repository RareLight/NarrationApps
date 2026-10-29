# Shared Qwen3-TTS, Chatterbox Turbo and Orpheus integration

Drafted and implemented October 27, 2026, across Libro, VoiceRelay, shared packages
and standalone Swift benchmark. The stages below retain the original design and
acceptance criteria; the completion record tracks current evidence separately.
This expands the earlier Kokoro/Soprano-only product scope while preserving
settings, queues, recordings, model assets and original benchmark artifacts.

## Outcome and scope

Both applications will offer the three selected model variants through the same
shared catalog, preparation/runtime adapters and narration Settings components.
Each selectable model must support installation, offline checking, every supported
preset voice, preview, long documents, cancellation, failure recovery and the
app's existing audio formats. VoiceRelay also needs durable captured settings,
checkpoint compatibility, publishing and timed transcripts for the new models.

The operator reported this bracket result:

1. Qwen3-TTS 1.7B / Ryan — top choice.
2. Chatterbox Turbo / default — runner-up.
3. Kokoro / Heart and Orpheus 3B / leah — contenders.

This is a user-reported preference shortlist, not a fabricated import of browser
votes or a completed held-out/long-form acceptance. Leave canonical benchmark
history untouched unless the operator's exported choices are explicitly imported.

Start with the **same checkpoints and precision that were heard**. Do not
substitute a smaller/quantized checkpoint because it shares a family name.

| Product model | Initial checkpoint | Complete voice coverage |
| --- | --- | --- |
| Qwen3-TTS 1.7B CustomVoice | `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` | Ryan, Aiden, Vivian, Serena, Uncle_Fu, Dylan, Eric, Ono_Anna, Sohee |
| Chatterbox Turbo | `mlx-community/chatterbox-turbo-fp16` | Bundled default conditioning; optional user-imported local reference-voice profiles |
| Orpheus 3B | `mlx-community/orpheus-3b-0.1-ft-bf16` | tara, leah, jess, leo, dan, mia, zac, zoe |

Qwen's preset voices can speak its supported languages: Chinese, English,
Japanese, Korean, German, French, Russian, Portuguese, Spanish and Italian.
Preserve speaker/dialect metadata, distinguish a voice's native language from
the selected narration language, and expose only verified runtime language modes.
Chatterbox **Turbo** and the selected Orpheus checkpoint are English models.
They must not inherit the multilingual claims of other checkpoints in the family.

Sources: [Qwen's speaker/language documentation](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice),
[Chatterbox's Swift adapter documentation](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioTTS/Models/Chatterbox/README.md),
[Orpheus's eight English voices](https://github.com/canopyai/Orpheus-TTS#prompting).
Chatterbox does not supply a finite named-voice menu like Qwen or Orpheus: its
Swift adapter uses bundled conditioning or a reference recording. Do not populate
it with names taken from a hosted provider's independently supplied voice library.

Kokoro remains supported in both apps; Soprano remains supported in Libro.
VoiceRelay's initial menu contains its existing Kokoro plus these three requested
models. Adding Soprano to VoiceRelay is not a prerequisite for this plan.
All existing saved choices and fresh-install defaults remain unchanged. Ryan can
be labelled as the operator's preferred voice, without automatically changing a
selection or downloading models. There is no restored 3× inference ceiling.

Additional Qwen Base/VoiceDesign/0.6B checkpoints, other Chatterbox variants,
multilingual Orpheus checkpoints, arbitrary third-party finetunes, hosted APIs,
Python runtimes and a product CLI are outside this initial integration. Supporting
all voices of the selected checkpoints does not require shipping every checkpoint
released under each family name. The catalog will permit separately validated
variants later.

## What exists and what must change

The pinned MLX-audio-swift revision is
`8d86630ade569728aaea3dc1a29fc44e2efa719b`. Its Swift implementations already
generated the bracket recordings. Keep that pin initially; an upstream update
must be justified by a reproduced adapter defect and validated independently.

| Current boundary | Verified constraint | Planned change |
| --- | --- | --- |
| `NarrationCore/SpeechSettings.swift` | Two models; non-Kokoro rate assumed to be Soprano's | Stable model/variant IDs and explicit capabilities/rates |
| `NativeSpeech/NativePrimaryCatalog.swift` and `NativePrimaryStore.swift` | Two primary inventories and Kokoro-specific voice files | Pinned per-variant primary/dependency inventories and voice validation |
| `NativeSpeechEngine/NativeSpeechWorker.swift` | Two concrete loaders; Kokoro preparation branch | Helper-only adapters for all selected models |
| `ProcessingPipeline/NativeSpeechSession.swift` | Soprano uses text; other models currently follow the Kokoro policy | Explicit per-model frontend and bounded preparation strategy |
| `NativeSpeech/SpeechAcousticIdentity.swift` | Non-Soprano provenance assumes Misaki/US or GB | Per-model acoustic identities and dependency provenance |
| `NativeSpeech/SpeechMemoryPolicy.swift` | 1 GiB MLX working threshold; host guard at most 3 GiB | Validated model-specific budgets and cross-app resident-memory policy |
| `VoiceRelayCore/NativeMLXBackend.swift`, `SpeechConfiguration.swift`, `NativeSpeechSetup.swift` | Backend/settings/setup explicitly construct Kokoro | Shared typed settings and model-aware setup/session creation |
| `VoiceRelayCore/Configuration.swift` and `SpeechQueue.swift` | Voice enum and locale derived from Kokoro IDs | Backward-compatible preferences and immutable per-episode model/voice/language |
| Libro controls and `SpeechSettingsPreference.swift` | Model-specific view branches; saved voice validation uses Kokoro | Shared presentation and model-qualified validated preferences |
| `NativeSpeech/VoiceSamples.swift` | Existing Kokoro/Soprano sample catalog | Samples and honest availability for every new preset |

The benchmark's generic `TTS.loadModel`/`SpeechGenerationModel` calls and asset
receipts are useful reference implementations. Do not make the shipping apps
depend on `BenchmarkCore`, copy its whole-passage PCM buffering, or use benchmark
labels as persisted product identities.

Important adapter details already verified in the pinned source:

- Qwen CustomVoice interprets `voice` as a speaker, optionally followed by an
  instruction. Product settings must keep those as separate validated fields.
- Orpheus is implemented by `LlamaTTSModel`; its loader requires SNAC separately.
- Chatterbox loads `conds.safetensors` and S3TokenizerV2. Some missing dependencies
  are caught by upstream code and replaced by defaults. Product adapters must
  reject incomplete requested conditioning instead of silently changing voices.
- Generic generation metadata is not uniform. In the benchmark's pinned SDK,
  Chatterbox's reported count can be PCM frames rather than generated tokens.
  Reuse the established distinction; never infer clean completion from that count.

## Shared design

Keep the existing ownership boundaries:

`app-owned captured settings → shared validated catalog/preparation → one private
helper/model → bounded native PCM → shared assembly/encoding → app-owned export
or publication`

The following descriptor/adapter names are proposed types, not existing APIs.

- **Model descriptor:** stable family and variant IDs, immutable model/dependency
  revisions, file inventories, precision, native sample rate/channels, supported
  languages, frontend, voice source, generation controls, preparation budgets and
  resource profile. Pure metadata belongs in NarrationCore/NativeSpeech and must
  not import MLX into either GUI.
- **Voice descriptor:** model-qualified stable ID, upstream speaker key, display
  name, native-language/dialect notes and sample identity. Qwen's installed
  `spk_id` configuration must agree with the shipped catalog. Orpheus's documented
  voice list needs an explicit maintained catalog because its prefix API does
  not enumerate valid names. Metadata changes never silently add untested voices.
- **Captured selection:** model/variant, voice or reference-profile ID/digest,
  language, applicable speed/style/generation parameters and preparation policy.
  Keep per-model last choices so switching families cannot carry `af_heart` into
  Orpheus or erase a previous Kokoro speed.
- **Helper adapter:** explicit load, prepare, synthesize and completion validation
  for each frontend. Reuse the upstream Swift architecture; keep any necessary
  dependency patches small, pinned, tested and documented with their owner.
- **Shared UI:** NarrationUI owns the model/voice/language controls, supported
  parameter presentation, samples and common setup presentation. Apps provide
  bindings and lifecycle actions; persistence, queue admission and publishing
  remain app-owned. AppPresentation stays independent of narration and MLX.
- **Selection guidance:** NativeSpeech owns a versioned, shipped catalog of
  generalized speed/narration-quality tiers and their evidence; NarrationUI owns
  the common meter/detail presentation. Advisory ratings never enter acoustic
  identity, queue settings, admission budgets or automatic model selection.

## Model-selection guidance: speed and quality meters

The October 27 UI requirement uses the supplied Superwhisper screenshot as a
visual reference for compact meters and model explanations. Shared controls are
implemented in Stage 6. The October 28 presentation below reflects the subsequent
compact-row request and supersedes the original always-visible card design.

### Presentation

Use two static, five-step horizontal meters with rounded tracks, equal widths,
aligned labels and a consistent accent fill. **More fill is better for both.**
These are rating indicators, not animated progress or processor activity.

| Element | Meaning and presentation |
| --- | --- |
| Generation speed | Relative throughput: Very slow / Slow / Moderate / Fast / Very fast |
| Narration quality | Curated naturalness, prosody and consistency: Basic / Fair / Good / High / Very high |
| Brief description | One sentence explaining the main tradeoff, without runtime implementation details |
| Model storage | Allocated downloaded-model bytes in the Settings inventory, separate from RAM requirements |
| Model details | An accessible trailing information button opens the description and meters |

Keep the main row compact: native model picker, download when missing,
and an adjacent ⓘ button. File size and deletion belong only in Downloaded models,
in compact fixed name/size/delete columns beneath folder controls.
Model, Voice, model-specific options and Play
Sample use compact, evenly spaced, left-aligned rows. The section fits only the
selected model's controls, keeping Model/Voice at the same origin. Speed keeps its value and arrows
together in the value column. The button opens a native popover containing
the description and both meters; no stats card is permanently visible. A cached
model shows only info beside the picker; an empty cache shows Download. Inventory
deletion asks for confirmation. Busy/unknown storage cannot trigger deletion, and
imported read-only folders stay protected. Shared support assets remain separate.
Download missing files in the
popover retains the existing repair/additional-language installation path without
requiring a model deletion. Opening details never installs, plays or loads a model.
The same keyboard-accessible controls serve both apps; lifecycle/storage remain
app-owned and all filesystem checks run asynchronously.

Adapt to text sizing, light/dark, increased contrast and narrow panes. Show a text
tier beside each meter so meaning does not depend on color. Expose an accessible
value such as “Generation speed: Fast, four of five,” without announcing a running
operation or percent complete. Missing ratings show “Not rated” and an explanation,
rather than an empty bar implying the lowest tier. Separate **Generation speed**
from the existing user-selected speaking speed; the meter is not an adjustable
speaking-rate control.

Suggested information copy:

> Relative estimates for model selection. Speed varies with your Mac, text,
> language and settings. Quality describes typical narration naturalness and
> varies by voice. Play a sample to compare.

### Generalized estimates, without a user benchmark

- Ship reviewed guidance metadata with the app. Opening Settings, highlighting a
  model or choosing a voice performs no local timing calibration, background
  model load, network lookup, telemetry or benchmark.
- Seed relative speed ordering from the retained common-corpus Apple Silicon
  benchmark and review comparable reproducible evidence when available. Use broad
  stable bands, not that machine's exact RTF, generation ETA or percent-speed
  claim. Qualify guidance by checkpoint/precision; do not promise a universal time
  multiplier on every Mac.
- Map the large throughput range to ordinal bands using documented thresholds
  on a logarithmic scale. Linear normalization would make most slower models
  indistinguishable beside Kokoro. Store thresholds and evidence with a guide
  version; adding one slower model must not automatically change every other tier.
- Maintain quality as a curated qualitative estimate from a common narration
  rubric and representative listening: naturalness, phrasing/prosody, stable
  delivery and noticeable narration defects. Comparable published listening
  evidence must retain its scope. Do not calculate quality from parameter count,
  speed, price, model marketing or speech-recognition accuracy.
- The reported bracket is evidence for the heard English voices, not a universal
  quality percentage or certification of every other speaker/language. Keep personal
  preference/recommendation badges separate from the general meter. Quality tiers
  need editorial review before release; do not invent precise per-voice scores.
- Use a model/variant-level speed guide by default. For quality, show the model's
  typical narration guide, with a voice/language-specific override only when
  evidence supports one. Explain inheritance in the info card. All voices remain
  selectable; an unrated voice/reference is not a runtime error. A custom reference
  cannot inherit a claim of evaluated speaker fidelity.
- Keep Kokoro's upstream voice training-data grades as a separately attributed
  detail. They are not a common cross-model listening score and must not be
  converted mechanically into the new narration-quality scale.
- A quality meter is not a speech-fidelity, pronunciation-accuracy or completeness
  guarantee. Source validation and generation-completion checks stay independent;
  samples/live previews remain the direct way to assess a particular voice.

Each guide entry records model/variant, applicable language/voice scope, tier,
brief rationale, evidence references, review date and guide version. Missing or
out-of-scope evidence uses “Not rated,” without guessing. Guide updates are
presentation-only: no checkpoint invalidation, queued-job changes, downloads or
silent switch to a highly rated model. Do not put private benchmark paths,
machine-specific elapsed times or an operator's private choices into product UI.

### Integration and validation

- Add guidance descriptors/catalog alongside model metadata in NativeSpeech and
  a reusable detail/meter view in NarrationUI. App-owned selections, persistence
  and lifecycle callbacks remain in their existing owners.
- Libro's narration controls/Models settings and VoiceRelay's Speech settings/setup
  chooser use the same view and guide entry. Cover all existing supported models,
  not just the three new families.
- Extend Stage 0 with the guide schema, speed-band calibration and quality rubric;
  extend Stage 6 with the reviewed catalog and shared views. Meters must work
  offline with no models installed.
- Add catalog/presentation fixtures for tier bounds, stable speed bands, variant/
  language/voice scoping, inheritance, missing ratings, evidence metadata, separate
  Kokoro grades and absence of inference/network work. Guide-only changes leave
  acoustic fingerprints and captured jobs unchanged.
- Add inert previews and operator checks for the selected card, optional hover/
  focus behavior, aligned meters, keyboard/VoiceOver, large text and narrow layouts
  in both apps. Reuse the consolidated Settings/model-selection checklist;
  compilation alone does not validate the final visual layout.

## Stage 0 — Freeze the integration contract and reproducible assets

Tasks:

- Preserve the current dirty workspace and completed Libro/VoiceRelay fixes.
  Record the source/dependency baseline without committing or pushing implicitly.
- Promote the heard variants into proposed production inventories using these
  benchmark model revisions:
  - Qwen 1.7B CustomVoice 8-bit: `41d3337e8b7f2843a75841595fc14e4b9a7a4b96`.
  - Chatterbox Turbo FP16: `b2d0a13aa7cfff0a06d9acb247ae91c8f19a6d75`.
  - Orpheus 3B BF16: `3786aac51797181edddeb0d89a8253deaee99aab`.
- Reconcile every required tensor shard/index, tokenizer, Qwen speech tokenizer,
  Chatterbox conditioning file/S3TokenizerV2 and Orpheus SNAC dependency. Record
  exact auxiliary revisions, sizes and digests before defining readiness.
- Verify model and conversion licenses/notices, including codec/tokenizer and
  reference/sample distribution terms. Preserve third-party wording. The
  Chatterbox upstream MIT/conversion-card Apache labels require an accurate
  attribution record, not an invented single license claim.
- Adopt existing verified local snapshots only through an explicit managed
  import/selection path; avoid forced multi-GB copies or downloads. Never modify
  or delete benchmark assets, canonical votes or generated audio.
- Audit the existing Swift adapters for bounded tokenization, completion reason,
  hidden network access and optional-dependency fallback. Identify any minimal
  local-directory loader/terminal-metadata patches needed by later stages.

Exit: a complete capability/voice manifest, auxiliary dependency inventory and
adapter gap list for the exact three checkpoints. No model is advertised ready
merely because its largest weight file exists.

## Stage 1 — Model settings, capabilities and compatibility

Tasks:

- Extend shared stable IDs without renaming `kokoro`/`soprano` or existing voice
  identifiers. Distinguish a family from its selected precision/checkpoint.
- Add backward-compatible decoding for new selection fields. An older job with
  no model field must resolve to the same Kokoro voice/speed it captured; never
  reinterpret a legacy queued job as Qwen because today's preference changed.
- Migrate Libro preferences and VoiceRelay's Kokoro-specific preferences through
  app-owned adapters. Preserve invalid/unknown records for recovery, keep usable
  settings readable, and isolate an unsupported job instead of losing a queue or
  forcing an unrelated default. Missing installed assets are not invalid settings.
- Add a family/frontend capability lookup. Replace `else == Soprano`, voice-prefix
  locale inference and assumed sample-rate shortcuts throughout preparation,
  setup, sample selection, readiness, previews and diagnostics.
- Expose only real controls. Preserve Kokoro's numeric speed behavior. Hide or
  disable numeric speed for a model without an equivalent validated native API;
  do not emulate it with resampling/time stretching or repurpose temperature as
  a speed slider. Optional Qwen style instructions remain a separate capability.
- Decouple narration language from speaker identity. All Qwen voices remain
  selectable in supported languages; unsupported language/model combinations
  receive a clear validation error rather than an English fallback.

Tests: legacy preference/job fixtures; per-model round trips and switches;
unknown variants/voices; absent assets; every voice ID and language; captured
settings unchanged during active work; unsupported-control validation.

Exit: both app adapters can capture and reload every new selection using pure,
model-free fixtures. Existing Kokoro/Soprano identities and behavior remain stable.

## Stage 2 — Shared model installation and offline readiness

Tasks:

- Generalize NativePrimaryCatalog/Store and ModelPreparation to install one chosen
  model and its complete dependency graph, with accurate aggregate progress,
  storage preflight, resumable/cancellable acquisition and atomic validation.
- Keep model stores app-owned by default and file inventories reproducible.
  Share implementation and optional validated immutable snapshots; do not silently
  merge app libraries, settings or benchmark directories into a new common cache.
- Only Install Speech Model performs network acquisition. Offline checks and
  generation load validated local directories with the network denied, including
  SNAC/S3Tokenizer/tokenizer post-load hooks. Patch/inject local dependency paths
  where needed instead of allowing an upstream `fromPretrained` download.
- Reject incomplete Chatterbox default conditioning and missing reference-voice
  dependencies. Do not accept upstream's default-token fallback as a successful
  load of a user-selected voice.
- Add model-aware setup/readiness to both apps. Installation or validation of one
  model must not cause another selected or captured model to appear ready.
- Preserve existing per-model installation locks, directory authorization,
  file/link validation and joined cancellation. Removal, if offered, must refuse
  assets required by active work and remain an explicit user action.

Tests: synthetic inventories, modified/missing shards and auxiliary files,
symlink/path attacks, cancelled acquisition, existing snapshots, disk failures,
concurrent setup, isolated caches and network-denied lazy dependency loading.

Exit: each selection can be installed and checked through the same shared API
from either app; a prepared installation generates without network access.

## Stage 3 — Helper adapters, bounded preparation and faithful completion

Tasks:

- Add helper-only Qwen CustomVoice, Chatterbox Turbo and Orpheus adapters using
  the pinned native Swift implementations. Keep one loaded engine per helper.
  Close/reap the prior session before changing incompatible models or voices.
- Keep semantic extraction, pronunciation overrides, source maps, footnotes,
  citations, scientific prose and PDF cleanup shared. Send Qwen/Chatterbox/Orpheus
  their native text frontend; never run them through Kokoro's Misaki phonemes.
  Preserve Kokoro's accepted spoken-form policy exactly. For non-English Qwen
  narration, English-specific transformations must abstain unless a separately
  validated locale policy exists; never translate prose or invent locale maps.
- Prepare long documents into model-bounded utterances at sentence/clause
  boundaries, preserving every spoken range and structural boundary. Use actual
  tokenizer/context capacity and codec/generation constraints, including prompt
  overhead. Benchmark 350-character chunks are a calibration starting point,
  not a claimed universal model-token limit. Oversized indivisible text fails
  with its source location; no silent truncation or dropped paragraphs.
- Capture versioned generation defaults matching the heard benchmark first.
  Record the seed where reproducibility is supported without claiming identical
  waveform bytes across arbitrary hardware/library revisions. Advanced style
  parameters, if exposed, are bounded, captured and included in identity.
- Require an authoritative clean terminal reason. Distinguish end-of-speech from
  max-token exhaustion, cancellation and malformed output. If necessary, add
  narrowly tested terminal metadata to the pinned adapter; token/PCM counts alone
  are insufficient, especially for Chatterbox. Never publish an incomplete tail.
- Materialize and spool finite mono Float32 PCM in bounded utterance-sized pieces.
  Preserve each engine's native rate, validate it against its descriptor, and
  enforce output-duration/frame/IPC limits. Do not copy the benchmark's document
  accumulation strategy into production. Streaming progress reflects actual
  emitted audio; a final-only adapter is not advertised as acoustic streaming.
- Keep model diagnostics off IPC stdout, limit/redact diagnostic tails and
  retain source text only in existing private opt-in records.
- Version the helper protocol once for any added settings/completion metadata;
  stale app/helper pairs fail clearly before synthesis. Update both embedded
  helpers and their bundle probes together.

Tests: every family/voice dispatch; token budgets and source coverage; language
validation; valid EOS versus token cap; Chatterbox count semantics; empty/NaN/
oversized/wrong-rate output; cancellation at load/preparation/generation/publication;
native dependency failures; stale helper; no partial output published. Existing
exact Float32, artwork and atomic replacement regressions remain required.

Exit: synthetic adapter fixtures pass before native smoke tests; real loaded
models produce bounded, cleanly completed artifacts through the production helper.
EOS is mechanical evidence, not a guarantee against model hallucinations.

## Stage 4 — Resource profiles and cross-app admission

This is a prerequisite for exposing the models, not a final tuning exercise.
The retained benchmark attempt records sampled these worker footprints:

| Heard profile | Sampled worker peak |
| --- | --- |
| Qwen 1.7B / Ryan | 5.14 GiB |
| Chatterbox Turbo / default | 4.60 GiB |
| Orpheus 3B / leah | 10.61 GiB |

These are local short-passage measurements from the comparison run, not safe
limits or predictions for every voice/long document. All exceed the current
production host guard of at most 3 GiB. The benchmark used a separate 16 GiB
worker guard; copying that global value into production would not establish
cross-app safety. Keep detailed local receipts private.

Tasks:

- Introduce explicit per-variant initialization/generation deadlines, MLX cache
  and working thresholds, sampled worker-footprint guards, text/token/output
  bounds and supported-memory guidance. Measure loading, conditioning, repeated
  utterances and long documents before choosing the actual numerical limits.
  Keep Kokoro/Soprano budgets unchanged unless independent evidence requires it.
- Retain one worker per app and Libro's interactive priority. An inference lease
  serializes GPU operations but does not unload an idle model from another app.
  Add a conservative resident-memory admission policy around the existing lease:
  acquire before loading, account for retained engines, and release/reap an idle
  incompatible large session before admitting another load when budgets require.
- Yield only at completed native-operation boundaries. A background session that
  must release residency can reconstruct/reload its captured model before the
  next utterance; do not interrupt GPU calls or replay already completed audio.
  Cancel while waiting must reap and remove only owned scratch.
- Preserve compatibility lock paths and exclusion with older app builds. Any
  residency metadata uses validated ownership/liveness and conservative handling
  of missing/unknown records. Do not treat an unaccounted resident as zero memory
  or introduce a new always-running daemon. Test stale-owner/crash recovery and
  mixed-version coexistence explicitly.
- Report waiting, loading and memory refusal honestly. No automatic downgrade
  to Kokoro, precision change or voice change after a memory failure. MLX limits
  and sampled guards are not a hard whole-machine memory cap.

Tests: model-budget lookup, low-memory refusal, stalled workers, cancellation,
priority, two-app combinations and model switches, resident release/reload,
stale metadata and legacy exclusion. Native tests on the comparison Mac include
Orpheus in one app while the other requests Qwen, plus repeated alternating jobs.

Exit: both apps remain responsive and never concurrently load incompatible
large resident sets under the validated policy. Actual-document memory acceptance
remains operator-owned, with separate host/helper measurements.

## Stage 5 — Acoustic identity, queue recovery, assembly and transcripts

Tasks:

- Extend acoustic identity/provenance with model/variant/precision, every relevant
  weight/tokenizer/codec revision, frontend/packing version, voice/reference digest,
  language and generation parameters. Keep packaging/assembly identity separate.
  Preserve legacy Kokoro/Soprano identity computation so unrelated unfinished work
  is not needlessly invalidated; new families receive explicit new versions.
- Reuse raw checkpoints only when captured acoustic inputs match. A changed
  voice, reference, language, checkpoint, conditioning or generation policy must
  not reuse another narrator's PCM. Compatible raw audio can still be reassembled
  after an encoding/pause-policy change, using existing integrity checks.
- Remove VoiceRelay's hardcoded Kokoro constructors in queue admission, runtime
  setup, backend factories, readiness, pronunciation preview and session reuse.
  Include full captured selection in backend/session identity so consecutive
  incompatible queued articles cannot share a stale engine. Preserve existing
  Kokoro constructor compatibility while migrating maintained callers.
- Capture new selections when enqueueing; preference changes apply only to later
  jobs. Retry/resume honors the job's captured model even if another model is
  selected in Settings. A missing model blocks that job with recovery guidance;
  it does not switch the job or starve otherwise eligible jobs.
- Preserve measured native-rate audio, zero-frame structural pause assembly,
  podcast resampling/encoding, covers and exact existing-output protection. No
  normalization, gain, limiting, silence trimming or crossfade is introduced.
- Generate VoiceRelay transcript cues from final prepared text and actual encoded
  audio intervals. If one utterance streams several PCM pieces, it is still one
  coherent text interval unless true text timing is supplied. Do not invent
  word alignment from audio chunks. Keep WebVTT/RSS/delivery behavior independent
  of model choice and preserve transcript-Off captures and finished episodes.
- Carry model/voice/reference identities through backup/restore, retained text,
  unfinished checkpoints and errors. Do not bundle multi-GB model weights into
  ordinary library backups. Reference-audio inclusion must be explicit and private;
  restored missing references stay actionable without default-voice substitution.

Tests: mixed-family queue, preference changes, cold restart/resume, fingerprint
misses/hits, changed references, corruption, backup/restore, missing assets,
preserved completed audio, measured transcript intervals and mock feed readback.

Exit: both apps generate and recover through their real orchestration layers;
all existing VoiceRelay publishing/source-removal/transcript regressions pass.

## Stage 6 — Shared Settings, previews and reference voices

Tasks:

- Add shared NarrationUI sections for model, voice, narration language, applicable
  controls, installation/readiness and voice samples. Replace duplicated Libro
  and VoiceRelay picker logic; keep shared text-size/help/rounded-section patterns.
- Include the shared guidance above: static generation-speed/narration-quality
  meters, text tiers, a brief tradeoff description, inventory disk usage and accessible
  estimate explanations. No user benchmark is required.
- Show all nine Qwen and eight Orpheus presets, with stable IDs and native-language
  notes, not a shortlist limited to the bracket entrants. Shared sorting labels
  must not describe Kokoro's upstream grades as grades for the new voices.
- Generate a licensed, bounded bundled sample for every new preset and Chatterbox
  default using the existing sample-generation workflow, with recorded checkpoint,
  settings, language and fingerprints. Samples require no installed model. Label
  their recorded language/speed; a language with no matching bundled sample offers
  a live preview rather than presenting English audio as a preview of that language.
  Live pronunciation
  previews use the actual selected model/voice/language and normal admission rules.
- Make model switching restore that model's last voice/controls and show its own
  setup state. An uninstalled selection is retained with an Install action;
  changing controls must not silently load/download a model. Keep current batches
  and VoiceRelay jobs immutable; settings remain independently app-owned.
- Include optional Chatterbox reference profiles as the supported way to add more
  voices. Use a shared native profile store/presentation so the same imported
  profile can be selected in both apps. Import only an explicitly selected local
  recording the user is authorized to use; no cloud upload or bundled impersonation
  library. Validate file/duration/channel/rate bounds and copy immutable,
  content-addressed reference bytes without altering their amplitude.
- A reference profile records a stable ID, display name, audio digest, format,
  language and conditioning/version metadata. Capture its digest with jobs; stage
  validated bounded bytes in the helper's owned workspace/spool instead of passing
  arbitrary external paths over IPC. Cache conditioning only by complete identity.
- Reference replacement/removal never changes an admitted job's captured bytes.
  Retain referenced versions while unfinished work needs them, handle missing
  assets explicitly and make backup inclusion visible. Reference profiles use live
  preview; they cannot claim to have a bundled static sample.
- Preserve all existing Libro queue/playback controls and VoiceRelay background
  startup/automation/publishing controls. Shared UI changes must not duplicate setup
  sections or write preferences/server state during rendering.

Tests: shared catalog/presentation fixtures and app binding adapters, every voice
option, per-model restoration, reference import/digest/version ownership, cancelled
preview cleanup and preview/setup failure states. GUI/Canvas checks cover both
apps, all Settings entry points, keyboard/VoiceOver, large text and narrow windows.

Exit: every supported voice is selectable in both apps, understandable when not
installed and usable in normal narration or a live preview after setup.

## Stage 7 — Integrate in preference order, preserving a working baseline

Implement stages 1–6 as vertical slices so each new model can be reviewed and
validated end to end before the next one becomes visible:

1. Shared descriptors/migrations, followed by **Qwen 1.7B** in both apps. Validate
   Ryan first, then every remaining preset/language capability; Ryan alone does
   not complete this slice.
2. **Chatterbox Turbo default** in both apps, then reference-profile support with
   the same shared storage/UI/runtime implementation.
3. **Orpheus 3B** in both apps, with every preset and its larger resource profile.
4. Finish mixed-model switching, cross-app residency, resume/backup/transcript
   and shared-UI validation across the complete matrix.

Do not finish a model by exposing a picker backed only by the developer benchmark.
Installation, offline checks, captured settings, real helper operation and recovery
must all work before that slice is enabled. Any guard/refusal is explicit; there
is no silent fallback narrator. New references/precision variants require their
own validated identity and resources rather than borrowing a family-level pass.

## Stage 8 — Validation and completion gates

Run tests serially at the tier level; do not overlap timing-sensitive fixtures
with heavyweight builds. Keep new test artifacts/model assets under ignored local
storage and never overwrite an installed operator candidate.

| Gate | Required evidence |
| --- | --- |
| Pure/model-free | Catalog completeness, migrations, capabilities, identity, source coverage, UI adapters, network-denied fake assets and failure/cancellation fixtures |
| Full fixtures | Root `bash scripts/check.sh`; both apps, shared packages, packaging/static/tooling regressions; preserve reported opt-in skips |
| Native offline | Every new preset produces finite nonempty correctly rated audio, clean completion and reaped helpers; missing dependency/language/voice/limit failures are tested |
| Long-form | Multiple chapters/articles/PDF-derived prose, names/numbers/abbreviations/paragraphs, utterance boundaries, repeated calls, memory growth and cancellation in both production app flows |
| Languages | Every advertised Qwen language and native-speaker coverage; English-only restrictions for the other selected checkpoints; no forced English cleanup on unsupported locales |
| Cross-app | All relevant model pairings, priority, waiting/cancel, idle residency release, switching, stale owners and mixed old/new lease compatibility |
| Persistence/delivery | Mixed queued models across restart, missing assets, compatible/incompatible checkpoints, references, backup/restore, covers, timed transcripts and mock verified delivery |
| Packaging | Debug and Release workspace builds plus both app Archives using `bash scripts/check.sh --tier release --adhoc`; verify helper-only MLX, arm64, resources/notices/samples/codecs, signatures and offline Metal probes |
| Operator acceptance | Held-out/long-form listening, GUI/Canvas/accessibility, actual documents, protected sources, normal-signed installed apps and live podcast/player behavior through the existing consolidated checklist |

Extend the existing native harness to select the new models/voices explicitly
before claiming coverage. No native model downloads occur inside ordinary tests.
Use existing verified local assets and explicit native-gate arguments; retain
source/build/asset receipts with all measurements. Track initialization versus
generation versus admission waiting separately. Test small/slow failures before
running an expensive all-voice long-form matrix.

The initial broad native smoke covers every preset. Deep long-form quality checks
start with Ryan, Chatterbox default, leah and the existing Heart baseline, then
expand to other presets/languages where smoke or listening reveals differences.
Runtime mechanics passing for one voice never establishes quality for all voices.
No arbitrary RTF target replaces the waived performance ceiling; report actual
latency, throughput, resources and estimated job duration so users can choose.

Extend existing operator IDs M01/L03/L09/L11/L12 and relevant VoiceRelay speech,
backup and transcript checks rather than creating a second competing manual
checklist. Listening should check omissions, repetitions, invented words, unstable
speaker identity, boundary artifacts, accents and sustained-listening fatigue.

Exit: implementation is complete only when both app paths and all advertised
presets pass their engineering gates. Report manual/unavailable gates separately;
do not relabel a build, tone fixture or EOS check as listening acceptance.

## Stage 9 — Documentation and handoff

- Update app guides, model/setup troubleshooting, shared architecture, Settings
  ownership, dependency/provenance/notices, voice sample inventory and AGENTS
  model lists after the corresponding behavior is implemented.
- Update implementation status with actual test/native/build evidence, measured
  resource profiles and explicit remaining operator acceptance. Keep this draft
  distinct from an implementation completion record.
- Retain the standalone benchmark and user-reported ranking. Add production-path
  comparisons for the selected checkpoints without changing the existing blind
  bracket's identities, decisions or audio levels. Reconfirm the preferred
  narration through production long-form preparation/assembly before proposing
  any new app default.
- Provide exact candidate locations and remaining manual steps. Do not commit,
  push, replace installed apps, change default voices or start live publishing as
  a side effect of finishing development.

## Principal risks and decisions

| Risk or decision | Planned treatment |
| --- | --- |
| Short-clip preference may not survive long-form packing | Preserve the exact heard checkpoints first; compare held-out and production long-form output before changing defaults |
| Heavy workers exceed current guard and can coexist while idle | Model-specific measured profiles plus resident-memory admission, safe-boundary unload/reload and two-app tests |
| Upstream lazily downloads codec/tokenizer assets or silently substitutes conditioning | Complete pinned dependency graphs, local loader injection, network-denied tests and explicit readiness/conditioning validation |
| LLM-style TTS can hit a token limit with usable-looking PCM | Reliable completion reasons, bounded preparation and rollback of incomplete unpublished output |
| New voices/languages collide with Kokoro-specific assumptions | Model-qualified IDs, explicit capabilities/frontends/locales, shared UI and old-data fixtures |
| A different family reuses old audio or stale sessions | Complete acoustic/session identity, immutable job selections and mixed-model resume tests |
| Reference clips are private and mutable | Explicit import, immutable digest capture, bounded local staging, version-aware retention and visible backup behavior |
| Native style/speed APIs differ | Expose only supported validated controls, keep speaker and instructions separate, preserve old per-model choices |

The design above is now implemented. See the completion record and
[current status](IMPLEMENTATION_STATUS.md) for measured engineering evidence,
conservative resource tradeoffs and remaining operator-owned acceptance.


## October 27–28 implementation record

Stages 1–7 are implemented through shared product paths: pinned primary and
auxiliary inventories, complete presets/languages, explicit installation/offline
checking, native-text adapters and clean-EOS guards, protocol version 3, model-aware
memory/deadlines, immutable queue settings and acoustic identities, shared controls,
reference profiles and 47 bundled samples. See [model selection](MODEL_SELECTION.md)
for current behavior. The full fixture gate passes, recorded in
`.local/validation/full-EB8A4A13-7243-4038-9C97-B2E0E7854A74/`; packaged and
extended native evidence is recorded below. Stage 9 updates the
current app/developer guides. Operator checks remain separate.

Large helpers are reaped after initial setup and after each utterance while
admission is held. This conservative implementation avoids overlapping large
resident sets without a new daemon or residency ledger, and preserves existing
lease paths/priority. It trades reload/hash-validation latency for predictable
residency. Existing small-model warm reuse is unchanged. Support guards require
16 GB for Qwen/Chatterbox and 24 GB for Orpheus; these are not whole-machine caps.

Cancellation during an asynchronous large-worker unload retains ownership until
the process is reaped, then rechecks closure/cancellation before returning ready
or publishing audio. A delayed-shutdown fixture reproduces the former early-reap
and late-publication race and passes with the fix. Offline inventory validation
also canonicalizes contained directory aliases and enumerates relative paths;
large file hashing releases each read buffer before reading the next one.

The pinned Chatterbox implementation applied peak normalization and an initial
fade internally. The product adapter disables both, and future benchmark runs use
the same raw-PCM mode. Original comparison recordings and rankings are retained;
re-listening is needed to compare this output policy. This is an explicit
departure from reproducing the original benchmark's amplitude processing.

Reference profiles retain original WAV bytes privately with content-hash IDs.
Deletion is intentionally unavailable while retained jobs may refer to them.
Ordinary library backups exclude recordings; reimporting the original clip
restores its ID after migration. No reference is replaced by the default voice.

Native short checks passed all nine Qwen presets, eight Orpheus presets,
Chatterbox default, all ten Qwen languages and a synthetic Chatterbox reference.
Receipts and output are retained under ignored
`.local/multi-model-implementation/`. Finite PCM, rate and clean completion are
mechanical checks; they do not establish pronunciation, translation fidelity or
long-form listening quality. The original 29 sample audio digests are unchanged.

Debug and Release workspace builds, both Archives and all six bundle audits pass
in `.local/validation/release-CF376C4F-5242-41A5-8105-B4247F18C718/` for the
working tree based on `c10135f`. The archives are ad-hoc engineering candidates,
not installed or normal-team-signed acceptance builds. The standalone benchmark's
26 isolated tests and final build also pass. Its original recordings and votes
are unchanged. Current candidate paths and remaining manual cases are in the
[operator checklist](OPERATOR_VALIDATION.md).

Final network-denied preparation and multi-paragraph narration pass through
**both archived helpers** for Qwen Ryan, Chatterbox default and Orpheus leah.
The synthetic passage contains three paragraphs, names, numbers and abbreviations;
each result has at least three prepared utterances, clean completion, native
24 kHz output and WAV/AAC artifacts. Receipts retain prepared plans and worker
hashes in `.local/multi-model-implementation/native-packaged-longform-libro/`
and `native-packaged-longform-voicerelay/`.

| Packaged helper/model | Audio seconds | Lifecycle and encoding seconds |
| --- | ---: | ---: |
| Libro / Qwen Ryan | 57.12 | 27.77 |
| Libro / Chatterbox default | 52.32 | 21.66 |
| Libro / Orpheus leah | 59.44 | 145.42 |
| VoiceRelay / Qwen Ryan | 63.84 | 31.85 |
| VoiceRelay / Chatterbox default | 52.16 | 22.83 |
| VoiceRelay / Orpheus leah | 57.65 | 136.89 |

These are bounded production-path checks on the local M2 Max/32 GiB machine,
not controlled cold/warm benchmark estimates or hour-long memory/listening
acceptance. The original benchmark remains the reference for static speed tiers.
Packaged contention also passes: waiting interactive Qwen runs before background
Orpheus, maximum resident helper count is one, all four helpers are reaped and
waiting cancellation publishes no output. The receipt is
`.local/multi-model-implementation/native-packaged-large-contention/contention.json`.
The aggregate `.local/multi-model-implementation/summary.json` records gates and
remaining acceptance; `source-digests.json` identifies the coordinated source.
