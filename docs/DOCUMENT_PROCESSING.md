# Document intake and narration

The shared DocumentProcessing and NarrationCore products are the canonical owners
of document parsing and source-faithful narration. Libro supplies local file access;
VoiceRelay supplies authorized web fetching, archive lookup and retained snapshots.
Those application responsibilities are not new shared network services.

## Intake and OCR

Foundation reads text/Markdown/RTF; existing pinned HTML extraction supplies semantic
web blocks. PDFKit text is preferred when usable. Scanned or unusable PDF pages use
bounded rendering and Vision RecognizeDocumentsRequest with structured paragraphs,
lists and tables; structures replace their child text once, avoiding double reads.
Mixed PDFs can use text and OCR on different pages. Complex reading order and OCR
accuracy still require comparison with the actual document.

Blocks retain page and authored/OCR/generated provenance. Footnote references and
omission notices survive the semantic boundary. Narration resolves known local
notes at their reference, retains unresolved/unreferenced notices conservatively,
and announces consecutive table/code omission runs once. Source prose is not
silently deduplicated. VoiceRelay retains title/source and article-ending cues;
Libro retains its document/batch workflow.

Preparation progress identifies file/structure work, page extraction/rendering/OCR,
a separate image review/description pass, planning and phonemization. A page bar
measures the current pass; unavailable totals use indeterminate progress. Speech
counts become final only after prepared utterances exist. Cancellation and stale
updates must not overwrite the next job or phase.

## Images, captions and deduplication

Authored web ALT and tagged PDF Figure/Alt take precedence over generated text.
Decorative/empty ALT images stay decorative. Conservative caption/credit, URL and
image-byte deduplication avoids repeated descriptions while preserving distinct
figures, distinct captions and ordinary body prose. Original blocks/provenance
remain available in the preview.

When enabled and available, on-device Foundation Models can produce a brief factual
image description. Work is bounded and joins the shared inference lease. There is
no cloud fallback or automatic model download. Web image retrieval is supplied by
VoiceRelay's bounded, public HTTPS, credential-free transport; local PDF imagery
stays local. Untagged PDF page imagery is not assumed to be isolated figure geometry.

The description preference defaults on; disabling it preserves authored text and
OCR. Unavailable/refused/failed imagery must leave source text usable. Generated
descriptions are labeled and may be inaccurate. Exact-caption quality and dedup
behavior are operator gates in the [single checklist](OPERATOR_VALIDATION.md).

## Integration and further work

Apps use the same semantic/prepared-speech boundary; avoid another parser, G2P pass
or app-owned normalization algorithm. Shared dictionary rules are captured once
for the owning job. Current pronunciation limitations and the next source-mapped
quantity-normalization increment are in [the research record](TEXT_NORMALIZATION_RESEARCH.md).
App-specific source/recovery behavior is in
[VoiceRelay's source guide](../../VoiceRelay/docs/SOURCE_REVIEW.md).
