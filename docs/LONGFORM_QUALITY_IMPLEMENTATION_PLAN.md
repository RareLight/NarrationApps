# Long-form narration quality — implementation plan

Authorized October 30, 2026. This plan covers the shared preparation, pronunciation,
delivery, verification and product-pipeline evaluation recommendations from the
October 29 research review. Automated evidence and operator listening acceptance
are separate. Existing recordings, captured settings, private sources and accepted
Kokoro pacing remain intact.

## Delivery and activation

**Subsequent operator decision, October 30:** semantic phrasing is now Kokoro's
only preparation path, without a user-facing toggle. Compound hyphens are protected
from dash pauses and utterance splits. Other models retain the opt-in experiment.
The original staged activation plan below records the comparison's development;
see [current behavior](LONGFORM_QUALITY.md).

Implement one shared versioned candidate, with the accepted policy retained for
comparison and old jobs. New controls are opt-in until paired listening validates
an improvement; no model/voice substitution, source rewriting, automatic emotion,
cloud recognition, downloads, waveform modification or unbounded retries. Both
apps consume the same libraries. Settings snapshots and fingerprints must capture
all acoustic choices. Already published recordings are never invalidated.

## Stage 1 — reproducible product-pipeline baseline

- Extend the existing Swift product-reference runner beyond Kokoro/Soprano to the
  supported shared models. Run actual NarrationPlanner/NativeSpeechSession paths.
- Add original synthetic sustained prose, dialogue, ambiguity, numeric forms,
  multilingual and PDF-like punctuation cases; preserve structure, not one giant
  paragraph. Keep the previous model benchmark and results readable.
- Support matched accepted/candidate plans and private preparation/parameter/PCM
  receipts, with blind aliases and original audio levels. Timing repetitions and
  load states must not become additional listening entrants.
- Provide explicit offline commands. Ordinary fixtures never load/download models.

## Stage 2 — bounded semantic segmentation

- Preserve accepted Kokoro target 200/hard 510 phones and baseline implementation.
  Candidate packing scores actual aligned phonemes at sentence/clause boundaries,
  permits bounded growth and protects indivisible terms and closing punctuation.
- Add shared sentence/word candidate planning using NaturalLanguage. Preserve
  dialogue, source structure, abbreviations, number-unit pairs and Unicode.
- Larger models prepare with their actual tokenizer budgets in the private helper;
  scalar/IPC bounds remain independent safety limits. Never treat character counts
  as token counts or cut/truncate unsupported words. Preserve sentence vs
  continuation vs paragraph/heading boundaries and exact source coverage.
- Retain source maps and captured pronunciation applications through repacking.
- Add source/budget/adversarial fixtures and record policy identity. Do not change
  accepted pauses, memory admission or large-helper residency.

## Stage 3 — scoped pronunciation and conservative spoken forms

- Backward-compatible dictionary schema: existing English respellings continue to
  load; add language, document scope and optional model restrictions. Document
  overrides outrank global entries. Rules apply once with complete mapped spans.
- Advanced Kokoro entries carry validated model-native phone strings separately
  from display text. Apply only at aligned token spans; reject unsupported phones
  or ambiguous alignment. Never interpret source prose as phoneme markup.
- Shared editor exposes advanced fields, sentence-context preview, explicit scope,
  and reviewable repeated-name suggestions. Suggestions do not become rules until
  approved. No guessed homograph replacement or generative rewrite.
- Compare actual Misaki contextual output on a fixed ambiguity set; retain its
  existing tagger/lexicon unless a reproducible port error warrants a narrow fix.
- Make written-to-spoken policy explicit per model/language. Keep accepted Kokoro
  expansions and existing protection/mapping rules; other frontends stay native
  unless the operator selects the separately evaluated candidate. Non-English
  paths must never receive English number expansions or legacy English aliases.

## Stage 4 — stable delivery and quality diagnostics

- Preserve selected voice/reference and custom Qwen instruction. Offer optional
  restrained Qwen narration instructions through the shared controls; no default
  instruction or inferred emotion/tags. No synthetic context prepended to speech.
- Add shared read-only PCM diagnostics for invalid/implausible duration, silence
  and suspicious repetition. Results are review flags, not a claim of semantic
  correctness; structural transitions remain relevant context.
- Add optional local Apple SpeechAnalyzer comparison, only with installed assets,
  bounded text/audio and cancellation. Missing support is explicit and never
  downloads or falls back to a service. Keep ASR separate from authoritative text
  and segment timestamps; do not call ASR a pronunciation oracle.
- Retain opt-in private chunk plans, hashes, settings and diagnostics for targeted
  same-model regeneration. Provide an explicit repair/export workflow that reuses
  valid chunks, replaces only the chosen span and reassembles measured timings.
  Never mutate published media/feed/transcripts as a side effect of review.
- Capture generation controls and per-chunk seeds where supported; do not promise
  cross-hardware bit-for-bit determinism. Existing defaults remain unchanged.

## Stage 5 — integration, documentation and validation

- Unit/regression tests cover old JSON, scope precedence, language/model selection,
  override alignment, uninterrupted source coverage, budget bounds, stable mapping,
  cancelled work, cache integrity, regeneration isolation and diagnostic abstention.
- App fixtures cover captured choices and shared controls; no GUI automation.
- Run focused checks first, then the full isolated fixture gate, benchmark fixtures,
  Debug/Release workspace builds and four bundle audits. Skip archives.
- Update current architecture, pronunciation/model/user guides, status/roadmap and
  the single operator checklist. Record exact automated receipts privately.
- Prepare offline paired listening commands/artifacts only after those checks pass.
  Do not invent listening scores or install models. Human validation compares
  multi-minute flow, names, numbers, dialogue and transitions for representative
  voices, plus controls, cancellation and cross-app sharing.

## Completion criteria

All stages have reachable implementations and meaningful passing automated checks.
The report must distinguish code completion, actual model-render evidence and
pending human/real-service acceptance. Numeric targets, optional normalization and
candidate activation stay experimental until the operator accepts them. Automatic
emotion inference, training/fine-tuning, automatic repair loops, parallel speech
workers, new model families and waveform mastering are outside this iteration.

## Implementation results — October 30

- Stage 1: Swift `tts-narration-quality` uses all five product engines and the
  actual shared planner/helper/assembly path. Five blind paired comparisons were
  generated, with private parameter/plan/audio receipts and portable choices.
- Stage 2: accepted and candidate policies coexist; actual-token native preparation,
  supported-phone packing, structural boundaries, exact coverage and bounded
  control windows are implemented. The accepted Kokoro target is unchanged.
- Stage 3: backward-compatible scoped schema, native trusted phones, context preview,
  repeated-name drafts and separate explicit English forms are implemented. Native
  US/GB override checks passed. No contextual model or guessed homograph rewrite
  was introduced; ambiguous passages remain in the listening corpus.
- Stage 4: shared presets, private chunk journals, screening diagnostics, installed-
  only local recognition and explicit streaming repair/continuation/export are
  reachable in both apps. Recognition itself remains an operator availability/
  quality check. Published media and transcripts are not repair side effects.
- Stage 5: full fixtures, benchmark fixtures, Debug/Release builds and four audits
  pass. Independent WAV/receipt inspection passed for ten native comparison clips.
  The native run also exposed and verified a fix for Qwen's premature heuristic
  output cap, retaining the declared hard ceiling and existing safety guards.

Exact evidence and remaining B09 acceptance are in
[current status](IMPLEMENTATION_STATUS.md#long-form-narration-quality--october-30)
and the [single operator checklist](OPERATOR_VALIDATION.md). The operator's
[October 30 paired listening](LONGFORM_QUALITY_LISTENING_RESULTS.md) preferred
semantic phrasing for Kokoro only; the remaining pairs were ties. Production
activation was subsequently approved for Kokoro only; GUI/recognition and the
hyphen correction's listening checks remain open.
No preference scores were supplied by an agent. Existing model-bracket history
and earlier recordings remain unchanged.
