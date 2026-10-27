# Documentation

Reviewed against the monorepo source on October 21, 2026. Start with your task;
implementation records are background, not additional setup instructions.

## Use the apps

| Task | Guide |
| --- | --- |
| Import documents/books and export audio | [Libro](../Libro/README.md) |
| Make a podcast from Safari Reading List | [VoiceRelay](../VoiceRelay/README.md), [detailed user guide](../VoiceRelay/docs/USER_GUIDE.md) |
| Choose voice previews, footnotes, citations and PDF cleanup | [Narration guide](NARRATION_GUIDE.md) |
| Correct a word or name | [Pronunciation](PRONUNCIATION.md) |
| Diagnose Libro setup, encoding, output or package errors | [Libro troubleshooting](../Libro/docs/TROUBLESHOOTING.md) |
| Understand VoiceRelay source failures or server conflicts | [Source handling](../VoiceRelay/docs/SOURCE_REVIEW.md), [server recovery](../VoiceRelay/docs/SERVER_RECOVERY.md) |

## Build, test and maintain

| Task | Canonical guide |
| --- | --- |
| Fresh clone, prerequisites, preparation and signing | [Contributing](../CONTRIBUTING.md) |
| Select quick/full/native/release checks and interpret evidence | [Development gates](DEVELOPMENT.md) |
| Compare TTS models/voices and run a preference bracket | [Swift benchmark utility](../tools/TTSBenchmark/README.md), [design and evidence](TTS_MODEL_BENCHMARK_PLAN.md) |
| Plan Qwen3-TTS, Chatterbox Turbo and Orpheus support in both apps | [Shared model integration plan](MULTI_MODEL_TTS_IMPLEMENTATION_PLAN.md) |
| Understand implemented features and current evidence | [Current status](IMPLEMENTATION_STATUS.md) |
| Find remaining acceptance and proposed work | [Roadmap](IMPLEMENTATION_PLAN.md) |
| Perform GUI/listening/account checks | [Operator checklist](OPERATOR_VALIDATION.md) |
| Work as an agent | [Root instructions](../AGENTS.md), then app/package AGENTS.md |
| Understand layout, Git ownership and original backups | [Repository layout](REPOSITORY_LAYOUT.md), [migration record](MONOREPO_MIGRATION.md) |
| Maintain documentation | [Documentation policy](DOCUMENTATION.md) |
| Activate CI or plan distribution | [CI](CI.md), [release checklist](../VoiceRelay/docs/RELEASE_CHECKLIST.md) |

## Technical references

| Topic | Guide |
| --- | --- |
| Shared pipeline, helpers, audio and recovery contracts | [Architecture](ARCHITECTURE.md) |
| Package products, Xcode integration and independent package publishing | [Package boundaries](PACKAGE_BOUNDARIES.md) |
| Parsing, EPUB/PDF/OCR, progress, mappings and images | [Document processing](DOCUMENT_PROCESSING.md) |
| Citation, margin, column and typography decisions | [Narration cleanup](DOCUMENT_CLEANUP.md) |
| Equations, prose insets, numeric tables and limits | [Scientific narration](SCIENTIFIC_NARRATION.md) |
| Shared versus app-owned Settings | [Settings ownership](SETTINGS_ALIGNMENT.md) |
| Voice sample resources and explicit regeneration | [Voice samples](VOICE_SAMPLES.md) |
| Synthetic regression ownership | [Regression corpus](REGRESSION_CORPUS.md) |
| Exact pins, patches, codec/model provenance and licenses | [Dependencies](DEPENDENCIES.md), [source provenance](PROVENANCE.md) |
| App-specific implementation | [Libro docs](../Libro/docs/README.md), [VoiceRelay architecture](../VoiceRelay/docs/ARCHITECTURE.md) |

## Review fix records

- [Libro and shared-component review fixes](LIBRO_REVIEW_FIX_PLAN.md).

## Research and implementation history

These records explain decisions and dated evidence. Their original stage commands,
counts, commit IDs and build paths are historical; use the current guides above.
Proposals in them do not automatically authorize further implementation.

- [Development foundation completion](DEVELOPMENT_FOUNDATION_CHECKLIST.md) and
  [original handoff](AGENT_HANDOFF_DEVELOPMENT_FOUNDATION.md).
- [Cover/navigation implementation](COVER_ART_AND_NAVIGATION_PLAN.md).
- [Kokoro longform implementation and listening decision](KOKORO_LONGFORM_IMPLEMENTATION.md).
- [Normalization research](TEXT_NORMALIZATION_RESEARCH.md) and
  [text-processing delivery record](TEXT_PROCESSING_IMPROVEMENT_PLAN.md).
- [Academic PDF evaluation and proposed research](ACADEMIC_PDF_EVALUATION.md).
- [Swift TTS model benchmark and evidence](TTS_MODEL_BENCHMARK_PLAN.md), prioritizing
  native MLX-audio-swift models, measured performance, a model/voice preference
  bracket and blind finalist listening.
  [Benchmark commands and evidence](../tools/TTSBenchmark/README.md).
- [VoiceRelay whole-app review fix plan](VOICERELAY_REVIEW_FIX_PLAN.md), covering
  publishing safety, source identity, captured pauses and transcript references.

Project commands default to the NarrationApps root. A guide must explicitly name
another working directory. Package-relative technical paths are labelled where
used. Private `.local/` evidence is optional local history, not a fresh-clone
prerequisite, and third-party source text/licenses retain their original wording.
