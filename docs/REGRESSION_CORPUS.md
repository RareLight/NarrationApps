# Canonical regression corpus

Inventory reviewed October 16, 2026. Fixtures stay with the implementation/tests
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
| EPUB, authored navigation/notes/cover | `DocumentProcessingTests/EPUBIntakeTests.swift`, `DocumentNavigationTests.swift`; generated EPUB 2/3 spine/metadata/ALT, unsafe archive failures, legacy absent metadata |
| Mapped quantities, letter A, punctuation, dictionary | `NarrationCoreTests/SpokenFormTests.swift`, `PronunciationTests/PronunciationTests.swift`; independent spoken text, captured overrides, omissions/source spans, original blocks |
| PDF margins/continuations and normalization | `NarrationCoreTests/PDFMarginTests.swift`, `PDFContinuationTests.swift`; conservative abstention, source mappings, full prose retention |
| Native regional phones, dotted leaders/subtokens, overlong words | `Fixtures/Longform/frontend.json` and [fixture provenance](../swift-packages/Tests/Fixtures/Longform/README.md); actual offline US/GB helper preparation |
| Vocabulary, 510-token ceiling, no truncation and legacy prepared plans | `NarrationCoreTests/PreparedSpeechTests.swift`; invalid vocabulary/alignment rejects explicitly; optional fields decode old artifacts |
| Worker protocol/prepared spool ownership and cleanup | `NativeSpeechTests/PreparedSpeechTransferTests.swift`, `ProcessingPipelineTests/SchedulingTests.swift`, `ModelPreparationTests.swift`; limits, invalid messages, joins, timeouts, ordered generation and atomic preservation |
| Original audio levels and final output safety | `AudioOutputTests/AtomicAudioWriterTests.swift`, `ZeroFrameAudioAssemblerTests.swift`, `NativeAudioTests.swift`, `ProcessingPipelineTests/AudioOutputFormatTests.swift`; exact Float32 including values outside ±1, no gain/clipping, podcast AAC/rates, cancellation preserves previous output |
| Art tagging without re-encoding | `AudioOutputTests/CoverArtworkTests.swift`; encoded packets/PCM, bounded derivatives and invalid cover preservation |
| Dictionary persistence and preferences | `PronunciationTests/PronunciationTests.swift`, `Libro/macos/LibroCore/Tests/LibroCoreTests/`; old/current saved values, explicit options and cover persistence |
| Retained snapshots, library/episode/settings compatibility | `VoiceRelay/Tests/VoiceRelayCoreTests/`; Store, SpeechQueue, LibraryBackup, AudioRetention, NativeSpeechAdapter, SourceReview and Delivery tests; synthetic SQLite, injected transports and old optional fields |
| Inert app lifecycle, Sync/setup, event ordering | `VoiceRelay/Tests/VoiceRelayAppTests/`; storage-injected models, cancellation/join, stale event protection, no live Safari/Keychain/server |
| Helper-only MLX, independent presentation, compatible locks | Root `scripts/check-contracts.swift`; parsed package graphs plus actual Xcode GUI products; transitive checks, six separately owned locks |

## Performance and native safety

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
