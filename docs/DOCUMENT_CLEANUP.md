# Narration cleanup and citation choices

Libro Settings → Document owns **Footnotes**, followed by
**Strip inline citations** and **Strip endnote citations**. Both citation choices
default off, including older saved preferences. The choices are captured with new
previews/batches; source files and finished audio are never rewritten. Shared
VoiceRelay controls and captured queue choices use the same policies. Control help
and collapsed examples explain the scope.

Inline stripping recognizes parenthesized author–year references. Numbered square
brackets require matching numbered entries in an identified reference list, so an
arbitrary array or `[12]` is not enough. Parenthetical explanations, dates, quantities,
code and uncertain alternatives remain. Endnote stripping omits explicitly marked
bibliographies, reference sections confirmed by multiple bibliographic entries,
and citation-only notes. Explanatory notes remain; the Footnotes choice still
controls their placement. EPUB 2 reciprocal superscript/backlinks can establish a
note even without EPUB 3 roles. A one-way numbered link alone cannot.

PDF margin cleanup is always enabled. Short labels need consistent, isolated
margin geometry and repetition across multiple pages, including local chapter
runs and alternating sides. Arabic/Roman folios additionally require sequential
evidence; consistent position and sequence can identify changing chapter labels.
Repeated body prose, unique chapter headings, legal/contact notices, missing or
uncertain geometry remain. No whole-page text is discarded because it contains
a matching phrase. Each omission retains its original block/page/range and reason.

Column reconstruction uses PDFKit's existing line evidence and separated gutters.
It reads supported two-column vertical bands left-to-right, top-to-bottom;
full-width text separates bands. Sparse, rotated, overlapping or irregular layouts
retain native order. It changes only the mapped spoken projection, preserving all
source text and its original extraction order. Old artifacts without line evidence
are not implicitly re-extracted.

Printed-word joining remains opt-in. Local line evidence permits joins inside
columns even when a page also contains headings or a second column. The platform
English spelling dictionary validates the joined word and preserves recognized
compound hyphens; unknown words abstain. Dictionary-verified uppercase letter
spacing can repair tracked titles and fragmented words while leaving ordinary word
pairs and ambiguous abbreviations alone. These rules do not infer missing text or
repair arbitrary OCR spelling. Layout/mapping budgets and cancellation still apply.

The [scientific-text follow-up](SCIENTIFIC_NARRATION.md) adds bounded equation
speech/source-reference cues and labelled table narration. It retains ambiguous
notation and recovered image-table text in the source rather than inventing values.

## Implementation choice

The existing PDFKit/Vision/SwiftSoup pipeline remains the maintained parser; a
small licensed Readium adaptation supplies optional word-joining logic, not a
Readium parser or runtime.
[GROBID's layout-token/segmentation approach](https://grobid.readthedocs.io/en/latest/Principles/)
and [PdfPig's column/XY-cut analysis](https://github.com/UglyToad/PdfPig/wiki/Document-Layout-Analysis)
inform the evidence requirements. Their additional model/service or .NET runtimes
do not fit this native application. No code from those projects, new dependency,
model download or network citation lookup is introduced. Standard Foundation
regular expressions and the platform spelling service provide the narrow text
checks. Recognizers deliberately abstain rather than delete uncertain information.

## Review and regression evidence

Synthetic citation, margin, column, typography, word-joining and EPUB-note tests
live with the shared packages. `DocumentReviewTests` is an opt-in private comparison
harness: supply `NARRATION_DOCUMENT_REVIEW_INPUT` and an isolated
`NARRATION_DOCUMENT_REVIEW_OUTPUT`, then filter that test with the normal SwiftPM
command. Without those explicit values it skips. It exports retained source,
both engines' default/joined/citation-filtered previews and selected PDF page
images into the supplied private directory. Do not commit those artifacts or book
prose; normal fixture gates do not access the books.

Actual-book engineering comparisons are separate from GUI/listening acceptance.
The current status and consolidated operator checklist record the completed gates
and remaining visual/listening checks.
