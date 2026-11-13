# Documentation

Reviewed against the monorepo source on November 12, 2026. Start with the guide
for your task. The archive retains dated implementation and validation records.

## Use the apps

| Task | Guide |
| --- | --- |
| Import documents/books and export audio | [Libro](../Libro/README.md) |
| Make a podcast from Safari Reading List | [VoiceRelay](../VoiceRelay/README.md), [detailed user guide](../VoiceRelay/docs/USER_GUIDE.md) |
| Connect a private client to local speech | [VoiceServer API](../VoiceRelay/docs/VOICESERVER.md) |
| Choose a model, interpret speed/quality meters and use reference voices | [Model selection](MODEL_SELECTION.md) |
| Choose voice previews, footnotes, citations and PDF cleanup | [Narration guide](NARRATION_GUIDE.md) |
| Understand seekable chapters, brief summaries and source links | [Chapters and show notes](CHAPTERS_AND_NOTES.md) |
| Correct a word or name | [Pronunciation](PRONUNCIATION.md) |
| Compare phrase boundaries, review names or check retained narration | [Long-form quality](LONGFORM_QUALITY.md) |
| Diagnose Libro setup, encoding, output or package errors | [Libro troubleshooting](../Libro/docs/TROUBLESHOOTING.md) |
| Understand VoiceRelay source failures or server conflicts | [Source handling](../VoiceRelay/docs/SOURCE_REVIEW.md), [server recovery](../VoiceRelay/docs/SERVER_RECOVERY.md) |

## Build, test and maintain

| Task | Canonical guide |
| --- | --- |
| Fresh clone, prerequisites, preparation and signing | [Contributing](../CONTRIBUTING.md) |
| Select quick/full/native/release checks and interpret evidence | [Development gates](DEVELOPMENT.md) |
| Track development milestones and commit-count builds | [Development versioning](DEVELOPMENT.md#development-versioning), [CHANGELOG.md](../CHANGELOG.md) |
| Compare TTS models/voices and run a preference bracket | [Swift benchmark utility](../tools/TTSBenchmark/README.md) |
| Understand implemented features and current evidence | [Current status](IMPLEMENTATION_STATUS.md) |
| Find remaining acceptance and proposed work | [Roadmap](IMPLEMENTATION_PLAN.md) |
| Perform GUI/listening/account checks | [Operator checklist](OPERATOR_VALIDATION.md) |
| Work as an agent | [Root instructions](../AGENTS.md), then app/package AGENTS.md |
| Understand layout, Git ownership and original backups | [Repository layout](REPOSITORY_LAYOUT.md), [migration record](archive/MONOREPO_MIGRATION.md) |
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

## Research and implementation history

Dated records live under [archive/](archive/README.md). They explain decisions and
dated evidence. Their original stage commands, counts, commit IDs and build paths
are historical; use the current guides above. Proposals in them do not
automatically authorize further implementation.

- [Development foundation completion](archive/DEVELOPMENT_FOUNDATION_CHECKLIST.md) and
  [original handoff](archive/AGENT_HANDOFF_DEVELOPMENT_FOUNDATION.md).
- [Monorepo migration record](archive/MONOREPO_MIGRATION.md).
- [Cover/navigation implementation](archive/COVER_ART_AND_NAVIGATION_PLAN.md).
- [Kokoro longform implementation and listening decision](archive/KOKORO_LONGFORM_IMPLEMENTATION.md).
- [Long-form quality implementation plan](archive/LONGFORM_QUALITY_IMPLEMENTATION_PLAN.md) and
  [listening results](archive/LONGFORM_QUALITY_LISTENING_RESULTS.md).
- [Normalization research](archive/TEXT_NORMALIZATION_RESEARCH.md) and
  [text-processing delivery record](archive/TEXT_PROCESSING_IMPROVEMENT_PLAN.md).
- [Academic PDF evaluation and proposed research](archive/ACADEMIC_PDF_EVALUATION.md).
- [Swift TTS model benchmark and evidence](archive/TTS_MODEL_BENCHMARK_PLAN.md), prioritizing
  native MLX-audio-swift models, measured performance, a model/voice preference
  bracket and blind finalist listening.
  [Benchmark commands and evidence](../tools/TTSBenchmark/README.md).
- [Shared multi-model TTS integration plan](archive/MULTI_MODEL_TTS_IMPLEMENTATION_PLAN.md);
  current model guidance lives in [Model selection](MODEL_SELECTION.md).
- [VoiceServer implementation checklist](archive/VOICESERVER_IMPLEMENTATION_CHECKLIST.md);
  the current user-facing guide is [VOICESERVER.md](../VoiceRelay/docs/VOICESERVER.md).
- [Libro and shared-component review fixes](archive/LIBRO_REVIEW_FIX_PLAN.md).
- [VoiceRelay whole-app review fix plan](archive/VOICERELAY_REVIEW_FIX_PLAN.md), covering
  publishing safety, source identity, captured pauses and transcript references.

Project commands default to the NarrationApps root. A guide must explicitly name
another working directory. Package-relative technical paths are labelled where
used. Private `.local/` evidence is optional local history, not a fresh-clone
prerequisite, and third-party source text/licenses retain their original wording.
