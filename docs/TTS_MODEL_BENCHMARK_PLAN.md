# Swift TTS model comparison plan

Drafted October 24; engineering and timed comparison completed October 25, 2026.
The user has removed the earlier 3× Kokoro performance ceiling for this
evaluation and confirmed that a standalone Swift command-line utility is welcome.
The purpose is to select better narration models, with measured performance as a
tradeoff, rather than eliminate candidates by speed before listening.
Listening compares model/voice choices only. Cold/warm load variants remain
performance measurements. A preliminary preference bracket selects a top choice
and runners-up before a separate blind finalist comparison. The October 25 user
correction makes the preliminary bracket blind too; it supersedes the original
named-bracket design. Local HTML/JavaScript now owns the listening interaction.
The follow-up passes 26 model-free tests and a standalone Release build. Browser
state/export/import logic is tested through JavaScriptCore; an isolated in-memory
WebKit fixture checks startup and responsive control alignment at three widths.
The source template has a distinct filename and a startup diagnostic. Local-file visual,
playback and permission checks remain with the operator. No synthesis rerun was
needed to generate the blind web app from the recorded audio.

## Implementation and evidence

The standalone [Swift utility and commands](../tools/TTSBenchmark/README.md) now
implement the host/worker protocol, explicit asset preparation and verification,
native model adapters, optional accepted-product reference, durable attempts,
performance reports, resumable preference bracket and held-out finalist workflow.
The coherent long-form fixture contains approximately 3,700 original words rather
than padding a shorter passage to the initial approximate 4,000-word target.

Automated validation on October 24–25 passed all 19 benchmark fixture tests, the
full project fixture gate, Debug and Release workspace builds, and all four bundle
audits. The installed Metal compiler required command-local toolchain selection;
no project deployment target, dependency pin or app setting changed. Fixture tests
cover output fidelity/validity, asset tampering, traversal, source coverage,
timeouts, memory bounds, descendant cleanup, cancellation, bracket progression,
ties/revisions/resume, duplicate entrants, executable/asset identity, evidence
combination, finalist timeout sizing and blind-pack identity separation.

Stages 1–5 are implemented. Stage 6's real-model smoke checks and initial timed
comparison completed on the M2 Max/32 GiB machine, separately from those gates:
12 direct model/voice profiles and two product references produced 224 recordings.
The campaign retained an initial zero-audio Emma failure: its generic-English
language selected the wrong regional frontend. A corrected `en-gb` profile passed
all 16 recordings in a separate run. The derived comparison preserves both source
runs, their executable hashes/build evidence and the failed attempt; no successful take was
replaced. Native dependency/patch identities match across the two runs.

Local evidence is under `.local/tts-model-benchmark/`: `campaign-20261024`,
`emma-20261025` and the derived `comparison-20261025`. The latter contains the
performance report and 12-entrant listening bracket. All 224 WAV hashes and
page audio links were checked. Timings are one seeded session order, not a
counterbalanced experiment; metadata is a starting power/thermal snapshot.
Initial profiles now default to a 30-minute timeout. Finalist timeouts grow from
measured request cost and all requested repetitions, with 50% headroom and a
two-hour minimum per profile.

Fish S2 Pro remains blocked until a licensed reference clip and transcript are
configured. No human preference has been supplied: Stage 6's bracket ranking,
blind listening and finalist long-form acceptance remain pending under operator
case [M01](OPERATOR_VALIDATION.md#model-evaluation-developer-utility). No model-quality
winner or app-integration decision is inferred from these measurements.

## Outcome and scope

Repurpose the existing evaluation work into a reproducible, local model comparison:

- Prefer models implemented in **MLX-audio-swift**, then other MLX implementations.
- Compare naturalness, prosody, reading fidelity, narrator consistency and fatigue
  alongside startup, sustained throughput, memory and operational reliability.
- Produce original native-rate WAVs, objective reports, a resumable pairwise
  preference bracket and a blind finalist listening pack.
- Keep model evaluation separate from adding models to Libro or VoiceRelay. A
  benchmark winner is a candidate for subsequent product integration, not an
  automatic change to defaults, settings, saved jobs or recordings.

Use Swift for orchestration, model adapters, audio handling and reporting. The
benchmark is developer tooling, not a new product CLI or Python runtime dependency.
Preparation and synthesis use explicit utility commands, separate from ordinary tests.

## Verified starting point

The older standalone `tts-bench` is absent from its former location. The user
believes it was removed during the Swift/Xcode migration. A targeted search of the
current root Git history found the shared-package introduction, but no tracked
`tts-bench` tree. Inspect relevant older history if available; do not restore old
Python runtimes, caches, private corpora or obsolete app repositories.

Reusable maintained code exists:

| Source | Reuse | Required change |
| --- | --- | --- |
| [LongformCheck.swift](../swift-packages/Sources/NarrationNativeCheck/LongformCheck.swift) | Supervised offline worker evaluation, corpus identity, timings, WAV validation/hashes and footprint evidence | It hardcodes three Kokoro voices, two speeds and two repeats. Each repeat prepares a new session, so do not relabel its results as resident-model warm measurements. |
| [make-longform-report.swift](../swift-packages/scripts/make-longform-report.swift) | Local HTML audio comparison, A/B labels and rating sheets | It expects four specific policy directories and 12 results each. Replace those assumptions with manifest-driven selections. |
| [Longform fixtures](../swift-packages/Tests/Fixtures/Longform/README.md) | Original synthetic prose and focused pronunciation cases | Retain existing fixtures unchanged; add separately versioned model-comparison cases. |
| [SpeechSettings.swift](../swift-packages/Sources/NarrationCore/SpeechSettings.swift) | Identify the current Kokoro/Soprano product references | The product enum supports only those two models. Do not expand it merely to run the benchmark. |
| [SpeechMemoryPolicy.swift](../swift-packages/Sources/NativeSpeech/SpeechMemoryPolicy.swift) | Explain production memory protections | Its approximately 3 GiB footprint ceiling is unsuitable as a universal limit for larger benchmark models. Keep the app policy unchanged. |

The [preparation script](../swift-packages/scripts/prepare-dependencies.sh) pins
MLX-audio-swift at `8d86630ade569728aaea3dc1a29fc44e2efa719b`, with maintained
project patches. The inspected checkout matches that base revision. It has a
`SpeechGenerationModel` protocol, local-directory loading through `TTS.loadModel`,
model defaults, and streamed audio/info events. Those are the starting API;
capabilities still need to be verified for each exact checkpoint.

The current [upstream model list](https://github.com/Blaizzy/mlx-audio-swift#supported-models)
is broader than the apps' two-model catalog. Upstream support, support in our pin,
checkpoint-format compatibility and a successful local smoke test are distinct
states. Record all four rather than treating a README listing as validation.

## Candidate order

Use one representative precision/checkpoint per model first. Additional bit depths
and runtime implementations are follow-up experiments, not the main comparison
matrix. Repository names below identify candidates, not approved downloads or
assertions that their entire dependency graph already works offline.

### Initial comparison

All these families have implementations in the inspected pinned Swift source.

| Family | Initial checkpoint/profile | Purpose and conditioning |
| --- | --- | --- |
| Kokoro 82M | Existing pinned `mlx-community/Kokoro-82M-bf16`; Heart 1.0×, then Michael/Emma | Accepted product anchor. Preserve the existing frontend, packing and pause identity for this reference. |
| Soprano 1.1 80M | Existing pinned `mlx-community/Soprano-1.1-80M-bf16` | Existing native alternative; retain its own text frontend. |
| Qwen3-TTS 0.6B and 1.7B | CustomVoice; start 0.6B bf16 and 1.7B 8-bit | Preset English narrator, initially Ryan; test Aiden separately. Neutral delivery first, then a documented narration instruction. Exact voice/instruction parsing must be checked in the adapter. |
| Chatterbox Turbo | `mlx-community/chatterbox-turbo-fp16` | Expressive English comparison, using its supplied default voice first and a separate reference-conditioned profile when available. |
| Fish Audio S2 Pro | `mlx-community/fish-audio-s2-pro-8bit` | Larger quality-oriented comparison with reference audio/transcript and native context handling. Keep research-license status visible. |
| Pocket TTS | `mlx-community/pocket-tts`; Alba plus another verified voice | Compare the Swift-supported checkpoint rather than assuming it is the new 18M release. |
| Orpheus 3B | `mlx-community/orpheus-3b-0.1-ft-bf16` | Expressive preset-voice comparison; start Tara, then a second verified voice. Use a quantized checkpoint only after compatibility preflight if memory requires it. |

The Qwen Swift documentation covers CustomVoice and its conditioning interface;
the [1.7B 8-bit conversion](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit)
is available. The [Fish conversion](https://huggingface.co/mlx-community/fish-audio-s2-pro-8bit)
is roughly 6.72 GB of weights; that is not a runtime-memory estimate. It uses the
Fish Audio Research License, so evaluation suitability and product distribution
eligibility must remain separate report fields.

### Expansion after the initial adapter pass

Prefer these already implemented families before writing new model ports:

- Chatterbox Regular: compare its distinct conditioning/emotion path with Turbo.
- Marvis 250M: `Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit`, starting with
  `conversational_a` and `conversational_b`.
- KittenTTS **0.8** mini/micro: inexpensive preset-voice controls. The implemented
  StyleTTS2-derived family does not establish support for **KittenTTS 2**.
- Echo TTS, IndexTTS, OmniVoice and MOSS-TTS: add after checking reference inputs,
  codec dependencies, local loading, license and memory requirements. Language-
  specific models enter only if they support the narration language being tested.

Hold Pocket's October small checkpoints and Chatterbox Nano as explicit
compatibility investigations; existing family support does not prove support for
those releases. Newer upstream-only models require a separately pinned benchmark
dependency upgrade and regression comparison. Supertonic 3 and other non-MLX
engines are optional later adapters, behind the native Swift/MLX candidates.
Do not automatically introduce Python as a fallback for an unsupported model.

## Architecture

The independent developer Swift package is at `tools/TTSBenchmark/`. It reuses
the maintained evaluation/reporting patterns after checking historical references,
without overwriting the existing Kokoro regression evaluator or its old reports.
The package uses the prepared pinned dependencies; it is not an app dependency.

Components:

- **Host executable:** validates a declarative run matrix, supervises one owned
  worker at a time, samples memory, records terminal states and builds reports.
  It does not link MLX.
- **Benchmark worker executable:** links MLX-audio-swift and runs a single selected
  model per process. Prefer `SpeechGenerationModel` and local model directories;
  add thin family adapters only for genuinely different inputs/options/events.
- **Product-reference adapter:** invokes the existing packaged speech worker for
  accepted Kokoro/Soprano app-path reference runs. Label these separately from
  direct model calls; IPC, preparation and assembly boundaries differ.
- **Versioned manifests and corpus:** lightweight Codable records, relative
  artifact paths and hashes; no global registration framework or database needed.
- **Report and listening generator:** consumes recorded artifacts without loading
  any model; builds the preference bracket, persists choices and creates the
  subsequent blind finalist pack.

Each model profile records checkpoint repo and immutable revision, all required
files/hashes and codecs/G2P/tokenizers, code pin and patches, precision, voice,
conditioning mode, language, generation parameters, seed policy, input limits and
chunking strategy. Unsupported options must fail explicitly instead of being
silently ignored. Keep family defaults initially; identical numeric temperatures
or token ceilings are not equivalent across architectures.

The [utility guide](../tools/TTSBenchmark/README.md) documents implemented commands
for inventory/preflight, explicit asset preparation, measured runs, reports,
preference-bracket progression and blind finalist-pack generation. A shortened
matrix supplies a separate smoke run; it does not replace the measured campaign.

## Fair comparison design

### Corpus and tracks

Start with English narration. Add original synthetic cases for short utterances,
multi-paragraph nonfiction, narrative prose, quoted dialogue, long sentences,
names, numbers, dates, units, citations and punctuation. Include questions,
parentheticals, contrastive emphasis and paragraph transitions to expose prosody.
Add one coherent approximately 4,000-word passage for long-form stability; avoid
building it by repeating the same paragraph. Private books/PDFs stay outside the
maintained corpus and are never required for reproducibility.

Keep three labelled tracks:

1. **Neutral narration:** identical frozen prose, no expressive tags or automatic
   text rewriting, using a verified preset/default voice where possible. Let each
   model's documented frontend handle text; never feed every model Kokoro phonemes.
2. **Conditioned narration:** reference-dependent models and instruction-controlled
   variants, with exact prompts/reference transcripts recorded. Use one licensed
   reference across compatible cloning models, disjoint from evaluation text;
   exclude its audio from output and timing denominators. Do not claim cloned and
   preset voices represent identical speaker identities.
3. **Long-form narration:** compare complete passages using each model's supported
   context/segmentation strategy. Preserve native context where useful; record
   chunk boundaries, limits, resets and inserted gaps. Do not force Kokoro's
   200-phoneme packing or structural pauses onto other families.

Required conditioning must never be omitted just to populate the neutral table.
Missing licensed reference material becomes an explicit blocked profile, not a
silent fallback voice. Give each family a small, fixed voice audition budget;
freeze eligible model/voice profiles before the preliminary bracket and select
finalists using calibration text separate from the blind scored passages. Report
model-plus-voice results rather than attributing every voice preference to
architecture.

Keep the app-reference track visibly separate. If a finalist sounds promising,
run an additional matched preparation/assembly experiment to estimate integration
effects; direct-model quality is not proof of quality through the app pipeline.

### Preference bracket, then blind finalist listening

Listening entrants are **model + checkpoint + voice/conditioning profile**. Each
entrant has one declared synthesis configuration and sample-selection rule.
Process-cold versus resident-warm loads, timing repetitions and equivalent runtime
or app-reference paths are never separate listening entrants. Their timing and
reliability results remain available in the performance report.

Use this sequence:

1. **Prepare eligible samples.** Use identical calibration passages for both sides
   of each match. Select the predesignated measured warm repetition for each
   entrant; retain the other repetitions as engineering evidence, not extra
   listening choices. A failed designated take is recorded as unavailable rather
   than silently replaced with a better render. Keep load-state and speed/memory
   figures out of the listening decision controls.
2. **Run the blind preliminary preference bracket.** Present one anonymous pair
   at a time with replay, optional notes, tie, neither and pause controls in the
   server-free local web app. Do not include model names in page data or audio
   paths. Keep the identity mapping in a separate file that the user may select
   for a final reveal only after finishing. Browser storage and portable JSON
   backups preserve progress without per-choice CLI entry. A one-time validated
   import synchronizes exported choices to the Swift finalist workflow.
3. **Advance winners and retain contenders.** Use a seeded, shuffled
   double-elimination bracket, including a grand-final reset when necessary.
   One loss moves an entrant to the consolation path; two losses eliminate it.
   This lets a strong narrator that meets the eventual winner early still reach
   the runner-up positions. Byes are explicit and are not recorded as listening
   wins. Do not force every candidate to defeat Kokoro first.
4. **Produce a provisional shortlist.** Record the bracket winner, second and
   third places, plus a fourth finalist when available. Label unresolved lower
   placements as tied/unranked rather than inferring a complete ranking from
   elimination round alone. Show the match history and allow the user to revisit
   a choice or retain an additional contender explicitly.
5. **Confirm with blind comparisons.** Freeze that shortlist, then create neutral
   A/B pairs using new held-out passages and long-form samples. Hide model/voice
   identity and bracket placement, randomize sides with a recorded seed and put
   mappings in a separate unblinding artifact. Compare finalists directly across
   passages; include the champion against each runner-up and resolve remaining
   runner-up ordering with direct pairs as needed. Report blind preferences
   separately; they may change the preliminary order or leave ties.

A tied preliminary match gets a second calibration passage; if unresolved, defer
it or explicitly retain both candidates for confirmation. Never break a listening
tie by speed, a random coin flip or an automatic quality score. “Neither” can
reject both entrants; failed, rejected and unassessed choices are distinct from a
recorded head-to-head loss. Fewer than four eligible entrants is a valid smaller
shortlist, not a reason to manufacture runners-up.

Persist the eligible roster, bracket seed/version, sample hashes, match IDs,
choices, notes, byes and advancement state. Resume without changing pairings or
silently replacing audio. Revising an earlier decision invalidates its dependent
matches and requests fresh choices while preserving the original decision history.
Use original or separately versioned samples for blind confirmation; do not reuse
the calibration text as held-out evidence. Voices can be recognizable, so describe
the final exercise as identity-hidden A/B listening rather than fully speaker-blind.

### Timing and repeatability

Use Release builds and a monotonic clock. For each selected profile:

- Measure process startup, local model load and reference preparation separately.
  Call fresh-process measurements **process cold**, not cold filesystem-cache tests.
- Discard one documented warmup, retain the loaded model for measured requests,
  and run at least three measured repetitions for short/medium passages. Repeat
  long-form finalist runs at least twice with recorded seeds where supported.
- Time through completed, materialized PCM: MLX lazy execution must finish before
  stopping the clock. Distinguish first usable nonempty PCM from first token,
  progress/info events and final completion. Record lack of genuine streaming.
- Record model-call wall time, full request time through WAV completion, and
  encoding time separately. Reference encoding cached across requests must be
  disclosed; downloads, compilation and transcription are outside inference timing.
- Rotate model-session order across rounds, run serially, and capture hardware,
  OS/toolchain, power/thermal state where available and interference indicators.
  Mark runs affected by competing inference as contaminated rather than silently
  merging them into the timing summary.

Preserve every attempt, including failure and cancellation. Record seeds without
claiming cross-model or cross-version bit reproducibility. Do not regenerate a bad
take and retain only a favourable sample. Checkpoint/precision variants remain
distinct configurations; do not average them into a model's headline result.

### Measurements and quality

Report medians and ranges with sample counts, not unsupported statistical certainty:

- RTF (`generation seconds / generated audio seconds`), reciprocal real-time
  throughput, and characters/words processed per second. Include output duration
  and speaking rate so slow delivery, omissions or excessive silence cannot make
  an RTF result look unfairly favourable.
- Startup/load/reference latency and time to first usable PCM when supported.
- Host and worker sampled peak physical footprint, MLX allocator peak separately,
  sampling interval, and available swap/memory-pressure observations. Allocator
  accounting is not total unified-memory usage.
- Completion/failure/truncation/repetition counts, invalid or silent PCM, native
  sample rate, frames, clipping indicators and output hashes. Token/output limits
  and timeout exits cannot be reported as successful complete narration.
- Optional offline ASR screening with one frozen recognizer and normalization
  policy, run after synthesis in a separate process. Retain raw transcripts and
  word-error details for inspection; names, numbers, repeats and endings need
  review. Do not install a recognizer implicitly or use WER as a prosody score.
- Blind human ratings: naturalness, phrasing/emphasis, pacing, pronunciation,
  voice consistency, long-form fatigue and overall preference. Allow ties,
  neither and unassessed. Automatic MOS predictors are optional diagnostics and
  must not become the narration-quality ranking.

Keep native-rate Float32 WAVs unmodified. No normalization, gain, leveling,
limiting, silence trimming, time stretching or crossfade. The listening page must
disclose that levels are unadjusted and let the operator note playback-volume
changes. Prefer WAV playback; optional shared-codec previews are separately
identified, preserve originals and disclose resampling/encoding settings.

## Isolation, assets and recovery

Use ignored `.local/tts-model-benchmark/` for assets, isolated caches, references,
run manifests, audio and reports. Commit only tooling, manifests/templates,
synthetic text, tests and documentation. Model preparation is an explicit network
step with revision/file verification; measured workers run offline, including
nested codec/G2P loads. Missing dependencies fail before measurement.

Audit loaders carefully: the pinned generic loader lacks local-directory support
for some families, and other loaders fetch ancillary assets. Implement small,
tested local-loading patches if required; never silently allow downloads in a
timed run or repin shared product dependencies to bypass the issue.

Use the shared inference lease at background priority, one active model worker,
and record admission wait separately. Yield between requests/chunks where the
model permits. Cooperative priority cannot preempt an in-flight GPU call; do not
promise it can. Keep the apps' production memory policy intact and give the
benchmark an explicit configurable worker budget with headroom checks on the
32 GB machine. Removing the speed ceiling does not require unbounded allocation.

The host enforces wall-time/output/memory bounds, owns process cleanup and joins
children on cancellation. Keep successful artifacts, atomically mark failed or
interrupted attempts, and resume only matching manifest identities. No automatic
precision downgrade, text truncation, voice substitution or retry masquerading as
the original profile. Scrub credentials, private text and absolute personal paths
from shareable reports; keep the full local evidence private.

## Implementation stages and acceptance

| Stage | Deliverable | Completion evidence |
| --- | --- | --- |
| 1. Inventory and contracts | Historical reuse decision; exact model profiles, dependency closure and capability/license inventory; versioned result schema | Every initial profile has a supported/blocked reason. Existing historical reports remain readable and unchanged. |
| 2. Swift harness | Independent host/worker package, serial supervision, offline preflight, bounds, durable results and fake worker | Synthetic tests cover timeout, crash, cancellation/reaping, interrupted resume, malformed events, missing assets, non-finite PCM and output-limit failures without loading models. |
| 3. Reference models | Accepted product-reference adapter plus direct Kokoro/Soprano evaluation | Explicit, prepared-asset smoke run produces valid WAVs and explains timing/preparation differences; app sources/settings remain unchanged. |
| 4. Native MLX candidates | Qwen3-TTS, Chatterbox Turbo, Fish S2 Pro, Pocket and Orpheus adapters/profiles | Each exact profile passes or records a bounded failure for offline loading, conditioning, short synthesis, input coverage and actual stream semantics. |
| 5. Reports and listening | Manifest-driven summaries, resumable preference bracket and separate blind finalist pack | Fixtures verify no cold/warm duplicate entrants, designated sample selection, seeded pairing/byes, two-loss elimination and final reset, tie/neither/defer handling, revision/resume, valid placements and hidden finalist labels, as well as report calculations, escaped text and audio links. |
| 6. Comparison campaign | Measured short/medium runs, preliminary model/voice bracket, then blind finalist and long-form confirmation | Immutable attempted-run ledger, provisional top choice/runners-up, held-out blind preferences and distinct quality/feasibility/integration conclusions. No default changes. |

Maintain a benchmark-local README with exact implemented commands, installation
size, explicit preparation, run presets, report interpretation and recovery.
Document a quick model-free check and a separately invoked real-model tier.
Benchmark tests must not enter normal app CI with implicit model downloads.
If implementation changes shared dependency/layout contracts, run the required
Debug/Release workspace gates as well as focused benchmark checks. Listening
acceptance remains with the operator.

The final recommendation should identify the preferred narrator profiles, their
observed advantages and failures, performance/memory cost relative to Kokoro,
license constraints, and concrete product-integration gaps. A model with excellent
short clips but omissions, drifting voices or poor long-form pacing should not
be promoted as the narration winner.
