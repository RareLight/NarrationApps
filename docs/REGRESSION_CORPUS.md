# Canonical regression corpus

Inventory reviewed October 21, 2026. Fixtures stay with the implementation/tests
that own their expectations. No duplicate corpus was moved or deleted. All
authored fixture prose is synthetic; generated PDF/EPUB/audio files are created
in owned temporary directories. Upstream phoneme expectations retain their pinned
provenance and notices. Expected values are reviewed, never silently regenerated.

Paths below are relative to `swift-packages/Tests/` unless prefixed with an app.
The root full tier runs all mandatory suites; quick scopes allow focused tests.

| Purpose | Canonical owner and expectations |
| --- | --- |
| Plaintext, paragraphs, legacy encodings/explicit override | `DocumentProcessingTests/IntakeTests.swift`, `TextEncodingTests.swift`, `TextFlowTests.swift`; original bytes/prose, inferred warnings and UTF-16 mappings |
| Markdown, RTF, HTML and inline code | `DocumentProcessingTests/SemanticIntakeTests.swift`, `IntakeTests.swift`; authored blocks, code protection and omission policy |
| Native PDF, OCR structure, images/caption dedup | `DocumentProcessingTests/PDFLayoutTests.swift`, `SemanticIntakeTests.swift`; bounded synthetic geometry, table/image provenance, no duplicate speech |
| Progressive Libro PDF previews | `DocumentProcessingTests/DocumentPreparationProgressTests.swift`, `Libro/macos/LibroCore/Tests/LibroCoreTests/DocumentPreviewAnalysisTests.swift`; early rounded/capped prefixes, cancellation before later OCR, cumulative limits, immutable prefix source and canonical final narration for both engines |
| EPUB, authored navigation/notes/cover | `DocumentProcessingTests/EPUBIntakeTests.swift`, `DocumentNavigationTests.swift`; generated EPUB 2/3 spine/metadata/ALT, unsafe archive failures, legacy absent metadata; fiction page-marker/footer exclusion with chapter, dialogue and intentional typography preservation across citation choices |
| Mapped quantities, letter A, punctuation, dictionary | `NarrationCoreTests/SpokenFormTests.swift`, `PronunciationTests/PronunciationTests.swift`; independent spoken text, captured overrides, omissions/source spans, original blocks |
| PDF margins/continuations and normalization | `NarrationCoreTests/PDFMarginTests.swift`, `PDFContinuationTests.swift`; conservative abstention, source mappings, full prose retention |
| Experimental PDF printed-word joins | `NarrationCoreTests/PDFWordJoiningTests.swift`, `DocumentProcessingTests/PDFLayoutTests.swift`; default/legacy preservation, native PDFKit lines, both engines, UTF-16 omissions, overrides, excluded sections, bounded page seams and dictionary-preserved compounds/unknown words |
| Academic citations | `NarrationCoreTests/AcademicCitationTests.swift`, `DocumentProcessingTests/DocumentNavigationTests.swift`; off-by-default independent choices, verified reference lists, explanatory-note/body preservation, reciprocal EPUB 2 links, geometric bibliography boundaries, source ranges and legacy/acoustic compatibility |
| Scientific equations and tables | `NarrationCoreTests/ScientificNarrationTests.swift`, `DocumentProcessingTests/ScientificIntakeTests.swift`; explicit linear grammar, one complex-equation cue per document in narration order, named display functions, inline/foreign-prose and wrapped-URL abstention, detached-limit geometry, zero-length whitespace mappings and override precedence; prose/merged tables, brief heading retention, numeric labels/disclosure, top/middle/bottom insets and captions, linked notes, targeted OCR limits and cancellation |
| PDF column/typography reconstruction | `NarrationCoreTests/PDFReconstructionTests.swift`, `PDFMarginTests.swift`; supported column order, wide titles, permutation/source preservation, safe column word joins, Roman/changing-label folios and dictionary-verified spacing with label-sequence abstention |
| Native regional phones, dotted leaders/subtokens, overlong words | `Fixtures/Longform/frontend.json` and [fixture provenance](../swift-packages/Tests/Fixtures/Longform/README.md); actual offline US/GB helper preparation |
| Vocabulary, 510-token ceiling, no truncation and legacy prepared plans | `NarrationCoreTests/PreparedSpeechTests.swift`; invalid vocabulary/alignment rejects explicitly; optional fields decode old artifacts |
| Worker protocol/prepared spool ownership and cleanup | `NativeSpeechTests/PreparedSpeechTransferTests.swift`, `ProcessingPipelineTests/SchedulingTests.swift`, `ModelPreparationTests.swift`; limits, invalid messages, joins, timeouts, ordered generation and atomic preservation |
| Original audio levels and final output safety | `AudioOutputTests/AtomicAudioWriterTests.swift`, `ZeroFrameAudioAssemblerTests.swift`, `NativeAudioTests.swift`, `ProcessingPipelineTests/AudioOutputFormatTests.swift`; exact Float32 including values outside ±1, no gain/clipping, podcast AAC/rates, cancellation preserves previous output |
| Art tagging without re-encoding | `AudioOutputTests/CoverArtworkTests.swift`; encoded packets/PCM, bounded derivatives and invalid cover preservation |
| Dictionary persistence and preferences | `PronunciationTests/PronunciationTests.swift`, `Libro/macos/LibroCore/Tests/LibroCoreTests/`; old/current saved values, explicit options and cover persistence |
| Retained snapshots, library/episode/settings compatibility | `VoiceRelay/Tests/VoiceRelayCoreTests/`; Store, SpeechQueue, LibraryBackup, AudioRetention, NativeSpeechAdapter, SourceReview and Delivery tests; synthetic SQLite, injected transports and old optional fields |
| Inert app lifecycle, Sync/setup, event ordering | `VoiceRelay/Tests/VoiceRelayAppTests/`; storage-injected models, cancellation/join, stale event protection, no live Safari/Keychain/server |
| Helper-only MLX, independent presentation, compatible locks | Root `scripts/check-contracts.swift`; parsed package graphs plus actual Xcode GUI products; transitive checks, six separately owned locks |

Libro's `QueueIntakePolicyTests.swift` covers explicit re-addition without
duplicating active/unrelated rows, processing-time overwrite/skip/cancel choices,
all-existing batches and late output creation. `FileDropTests.swift` and shared
`EPUBIntakeTests.swift` cover unpacked EPUB discovery as one document, stable
normalization, matching prose/cover, resource-link rejection, budgets and cancellation.
`QueueOrderingTests.swift` covers multi-row insertion indices, retained scan order,
reordered progress and compact status labels. Shared `BatchQueueControlTests.swift`
and `SchedulingTests.swift` cover pause/resume, releasing background admission,
reordered execution, late/stale Skip, output preservation, stopped paused waiters
and cancellation accounting after a reorder, using isolated fake workers only.

## Performance and native safety

Harness source paths in this section are relative to `swift-packages/`.

The native tier reuses `Sources/NarrationNativeCheck/MixedDocumentCheck.swift`:
12 synthetic PDF pages plus 600 Markdown words, both engines, one worker.
It reports host and helper footprints separately. `ContentionCheck.swift` tests
priority, cancellation and helper reaping. Model-free Scheduling/transfer/admission
fixtures assert hard failure limits without elapsed-time throughput requirements.
There is no new global timing threshold or claim of a whole-system memory cap.

Use fixed hardware/toolchain and repeated same-machine runs for throughput trends;
retain actual hardware, SDK, source and workload fingerprints with any baseline.
No new performance baseline is claimed by this inventory. Real document layout,
OCR/caption quality and listening stay in [operator validation](OPERATOR_VALIDATION.md).
Never add private books, recordings or generated expected values to Git to make
those gates appear automated.

## October 30 long-form quality candidate

`NarrationCoreTests/LongformQualityTests.swift` covers semantic/phone budgets,
Unicode coverage, sentence completion, mandatory Kokoro policy with legacy settings,
atomic compound handling without dash phones, dense trusted-phone control payloads,
explicit English spoken forms and read-only diagnostic/WER bounds.
`PronunciationTests/ScopedPronunciationTests.swift` owns language/document/model
precedence, schema migration, stable identity and conflict preservation.
`ProcessingPipelineTests/NarrationReviewTests.swift` owns immutable plans,
per-chunk integrity journals, exact PCM/export frame intervals, explicit repair,
missing-passage continuation, historical Kokoro re-preparation with unchanged PCM
reuse, and cancellation with a model-free helper.
`PronunciationUITests` owns sentence context and joined review ownership.
The benchmark's `QualityComparisonTests.swift` checks anonymous local page data;
actual native helper rendering and the US/GB phone-override check are explicit
separate runs. Recognition availability, Safari and listening remain B09.
