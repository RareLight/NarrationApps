# Scientific text, equations and tables

The scientific follow-up uses native PDFKit/Vision evidence and the existing mapped
spoken projection. It changes narration, never the supplied PDF or retained native
prose. Both engines use the same equation/table policy. No model, service, runtime
or package dependency is added; audio/frontends and user pronunciation overrides
remain separate. These automatic rules have no additional Settings controls.

## Equations

An isolated PDF display expression may be read as words when its extraction is a
single reliable line and a bounded grammar accounts for every token. Supported
notation includes explicit arithmetic/comparisons, parentheses, named elementary
functions, Greek variables, underscore numeric subscripts, caret powers and Unicode squared/cubed.
For example, `x² + y² = r²` becomes “ex squared plus why squared equals ar squared.”
Uppercase variable names say “capital”; a middle dot stays “dot,” preserving its
distinction from a multiplication sign.
The grammar never treats `x2` as a known exponent or subscript, guesses an omitted
multiplication, repairs a misdecoded operator, or infers a fraction from the order
of disconnected glyphs.

When a supported display-region detector finds complex or undecodable math,
narration says **“For full equations, refer to the original text.”** once per
document, at the first such expression in actual narration order. Later pages,
headings and intervening prose do not reset that notice. Every detected region
still has an omission record with the original UTF-16 range, page and recoverable
equation number. Surrounding prose, variable definitions,
ordinary numbers and inline sentences are retained. Baseline checks distinguish
inline fragments from display equations; unsupported/rotated/missing geometry
abstains. Source-map composition also checks that no interleaved prose is crossed.
Zero-length prior whitespace edits do not count as intervening spoken content.

This is an explicit alternative to reading a broken glyph stream, not a semantic
summary of a derivation. Complex matrices, stacked fractions, lost super/subscripts,
and ambiguous chemical notation are not reconstructed. Detection is conservative:
some inline notation, equations with prose-like identifiers and unrecognized
layouts remain in native form. Missing PDF ligatures and incorrect font encodings
can already damage the source text; these rules do not restore missing letters.
Compare the original before relying on scientific details.

[MathCAT](https://github.com/daisy/MathCAT) remains research for a future MathML
path. The current scope deliberately supports simple expressions and one reference
notice for detected complex display math; advanced mathematical transcription is
deferred. No math engine dependency is added.

## Tables

Verbose table entries read as ordinary prose, keeping each row's text and brief
labels/quantities together. Predominantly prose tables retain short section
headings as well. Explicit headers appear once, captions remain with the content,
and generated row/column labels and end-table announcements are unnecessary for
these prose insets. Ragged or merged cell relationships do not prevent reading
their reliably extracted prose in source order.

Numeric grids still require reliable cell relationships. HTML tables with a complete first row of
`th` cells use those headers. Unknown header semantics (including OCR and legacy
pipe-delimited cells) use numbered columns and retain the first row as data. Mixed
row headers do not cause the first data row to be lost. This follows the principle
of associating each value with its labels in the
[W3C table guidance](https://www.w3.org/WAI/tutorials/tables/).

Rectangular numeric tables of 1–8 columns and up to 40 data rows read every entry, including
numeric values, with labels and an end-table cue. Larger tables retain verbose
entries (at least six lexical words with 24 letters in any cell, including a descriptive first column)
and explicitly state the number
of remaining brief/numeric rows. Predominantly prose tables retain all rows within
the limits, including brief headings. No statistic, conclusion or “representative”
row is invented. Limits are 200 rows, 32 cells per row and 32,000 cell-text UTF-16
units for prose; unreliable numeric relationships get a source-reference cue.
Untagged native PDF tables without reliable cell boundaries retain their original
extraction; this increment does not infer their grids from whitespace.
All original cell text remains in the semantic source. Repeated unavailable-table
cues can collapse across adjacent nonverbal material as before; readable tables
are not collapsed. Code blocks keep their existing omission policy.

For native-text PDFs, a caption above an otherwise text-free lower page area,
combined with an image resource and compatible page geometry, can establish that
an image-only table is missing from the text layer. Only that bounded region is
rendered for local structured OCR. Native prose and line evidence remain unchanged;
recovered cells are separate OCR-provenance blocks. Recognition is capped at 20
candidate pages and shares the existing OCR page/time/text limits and inference
lease. Cancellation propagates. Optional recognition failure or exhausted budgets
leave a table-image cue rather than failing readable prose. Without a reliable
grid, OCR strings are retained for review but are not assigned guessed labels.

## Inset placement defaults

Preserve authored HTML/EPUB order and resolved footnote links, including the user's
chosen note placement. Do not infer an association from a bare “Table 3” mention.
For recognized OCR table insets, keep whole body paragraphs intact. A table stays
at its first covered paragraph; if it has no covered paragraph, place it before
the next paragraph below it in the same column. Tables entirely in the lower
quarter follow the page body. Nearby unambiguous numbered captions travel with
the table. Do not collect all insets at the end of the book. Missing or uncertain
geometry retains extraction order. Native untyped table text also retains its
existing source flow.

These are narration defaults derived from usable structure and geometry. The
[W3C reading-order guidance](https://www.w3.org/WAI/WCAG21/Techniques/pdf/PDF3)
also notes that complex PDF layouts may need reading-order correction; it does
not prescribe a universal physical position for insets.

## Evidence and remaining acceptance

`ScientificNarrationTests` and `ScientificIntakeTests` cover the grammar, source
ranges, inline/foreign-prose abstention, whitespace-map composition, table labels,
row-header preservation, long numeric disclosure and targeted image-table OCR with
injected recognition, budgets and cancellation. Normal fixtures use synthetic
content and never access supplied books or invoke native document recognition.

The explicitly authorized private PDF reviews, source/preview exports, renders and
reports stay in `.local/science-review/`. Current status records the actual gates.
Headless text/preparation comparisons are separate from GUI and listening
acceptance. Unreliable source encodings, detailed notation and image-table OCR
quality remain visible limitations, not claimed scientific transcription accuracy.

The [broader academic PDF evaluation](ACADEMIC_PDF_EVALUATION.md) adds public papers,
OCR/structured-HTML comparisons and an implementation recommendation. It also
protects wrapped URL queries and prevents overlapping equation fragments from
being asserted as complete linear expressions.
