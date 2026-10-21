# Difficult academic PDFs: evaluation and next steps

October 19, 2026. This expands the [scientific narration](SCIENTIFIC_NARRATION.md)
review with five public papers. Downloaded papers, extracted prose, renders and
model/settings exports stay in ignored `.local/academic-corpus/`; third-party full
texts are not bundled as fixtures. Its `audit.json` records versions, input hashes,
page counts, source comparisons and plan checks. `run-final.sh` reproduces the
explicit local reviews. Normal fixture runs use synthetic material only.

## Corpus and observed limits

| Paper / selected version | Pages | Difficult structures |
| --- | ---: | --- |
| [Attention Is All You Need, v7](https://arxiv.org/abs/1706.03762v7) | 15 | Full-width floats, multi-line formulas, mathematical table cells |
| [Adam, v9](https://arxiv.org/abs/1412.6980v9) | 15 | Algorithm mixed with explanations, stacked sums/fractions, long derivations |
| [BERT, v2](https://arxiv.org/abs/1810.04805v2) | 16 | Two columns below wide tables, footnotes, inline notation |
| [LIGO detection paper, v1](https://arxiv.org/abs/1602.03837v1) | 16 | Units, uncertainty bounds, figures, bibliography URLs and long author lists |
| [PRISMA 2020 statement](https://doi.org/10.1136/bmj.n71) | 9 | Long descriptive checklist, merged cells and rotated publishing sidebar |

Each PDF is reviewed with both engine planning paths and default, word-joining and
citation-filtered options. This is a 71-page sample, not a representative accuracy
benchmark. A completed plan does not establish correct reading order or scientific
speech. Source-range checks and representative complete-page visual inspection
are recorded separately from fixture execution and listening acceptance.

The PDFs retain native prose, but none has a PDF structure tree or produces typed
native table blocks in the current intake path. Their table text remains flattened.
Attention's named/multiword
formula identifiers and BERT's inline notation also illustrate conservative math
detection gaps: no equation cue does not establish a clean formula. Adam's algorithm
mixes meaningful comments and notation; automatically dropping the entire algorithm
would lose information. Long author lists are retained, not silently classified as
running headers. These remain engineering work, not completed extraction features.

PRISMA reports layout evidence unavailable on all nine pages. Its rotated publishing
sidebar and running material remain in native text; layout-based margin/column
cleanup abstains. The cause of the geometry failure has not been isolated. A native
follow-up should localize that failure and retain independently verified regions
alongside unmapped source text, rather than requiring usable geometry for an entire
page. This must preserve all uncovered text and source offsets.

The review reproduced and fixed two narrower errors with synthetic regressions:

- A URL's wrapped query could look like an isolated equation. The continuation now
  retains its URL context rather than receiving mathematical speech.
- A detached summation limit could parse as a complete linear equation. Overlapping
  geometry now prevents that assertion; uncertain math receives a source cue.

## Comparative experiments

Local Apple Vision document recognition was run independently on table-bearing
pages: Attention 6, BERT 6, LIGO 7 and PRISMA 4, plus Adam's algorithm on page 2.
It found table grids on the Attention and LIGO samples, but not the BERT or PRISMA
samples. Even the detected rectangular grids had incorrectly recognized operators,
exponents, units or uncertainty bounds. A rectangle and cell count do not establish
numeric correctness. These diagnostic alternatives were not substituted into the
retained native prose. Diagnostics used full-page renders at three pixels per PDF
point, automatic language detection and language correction disabled; they are
not an exhaustive comparison of OCR configurations. Earlier exploratory pages without tables are not counted as
table misses. See Apple's [document API](https://developer.apple.com/documentation/vision/recognizedocumentsrequest)
and [table example](https://developer.apple.com/documentation/vision/recognize-tables-within-a-document).

Downloaded arXiv HTML for Attention and BERT supplies 142 and 111 MathML elements,
respectively, along with explicit tables. The current HTML intake was also tested
on those snapshots. Its generic text traversal flattens math and can duplicate
presentation text with embedded TeX annotations; equation layout tables can become
ordinary narrated tables. Thus simply preferring today's HTML importer is not a
complete remedy. Adam's HTML endpoint contains a PDF pointer rather than a usable
article, so availability alone is insufficient. arXiv explicitly describes its
[HTML conversion as experimental](https://info.arxiv.org/about/accessible_HTML.html).

## Current scope and remaining research

The subsequent narration policy prioritizes inset text flow and readable prose
over reconstructing table grids. It also limits complex-equation speech to one
document-level source reference; advanced equation transcription is deferred.
See [current defaults](SCIENTIFIC_NARRATION.md). The broader options below remain
research, rather than a requirement to add advanced mathematical support.

1. **Preserve article structure before flattening.** Add a scientific HTML/MathML
   path that retains the math tree, separates alternative annotations from spoken
   text and distinguishes layout equations from data tables. Validate article
   identity/version, section coverage and numeric text before preferring it over
   a PDF. [JATS XML formulas](https://jats.nlm.nih.gov/publishing/tag-library/1.4/element/disp-formula.html),
   [tables](https://jats.nlm.nih.gov/publishing/tag-library/1.4/element/table-wrap.html)
   and reliable PDF structure tags are other sources of explicit relationships.
   Keep alternate-source selection explicit; never silently replace
   a private PDF with an online version.
2. **Review and re-analyze regions.** Show the original page crop alongside native
   and OCR alternatives, with a page/region link for unresolved math or tables.
   Re-analyze only selected regions. Keep authored/OCR/generated provenance, bounded
   budgets, cancellation and progressive preview behavior. Require agreement or
   review for scientific numbers, signs, units and super/subscripts; do not infer
   confidence from successful OCR execution.
3. **Use a maintained math speech engine after recovering structure.**
   [MathCAT](https://github.com/daisy/MathCAT) accepts MathML and offers C/C++ bindings.
   It is a candidate for a native integration, not a solution for missing PDF
   structure. Preserve original notation and allow explicit math detail choices.
4. **Benchmark alternate extraction, then decide integration.**
   [Docling](https://docling-project.github.io/docling/) provides layout, reading
   order and table extraction; its [formula models](https://docling-project.github.io/docling/_generated/examples/code_formula_granite_docling/)
   warrant a controlled comparison. [GROBID](https://grobid.readthedocs.io/en/latest/Introduction/)
   specializes in scientific document segmentation, references and TEI with PDF
   coordinates. Neither was installed or benchmarked here. Their Python/model or
   Java/service deployment costs do not fit the existing native app by default;
   evaluate them as offline comparators before proposing a product dependency.

Acceptance should include paragraph/column order, caption association, table
cell-to-label relationships, units/uncertainty bounds and equation coverage, plus
false positive checks on prose and URLs. Keep the general synthetic regressions and
the versioned local corpus: adding more cleanup substitutions cannot restore a
missing mathematical tree. Current status and private reports record the actual
executed gates; GUI and listening remain operator-owned.
