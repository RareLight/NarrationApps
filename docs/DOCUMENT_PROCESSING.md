# Document intake and narration

The shared DocumentProcessing and NarrationCore products are the canonical owners
of document parsing and source-faithful narration. Libro supplies local file access;
VoiceRelay supplies authorized web fetching, archive lookup and retained snapshots.
Those application responsibilities are not new shared network services.

## Intake and OCR

Foundation reads text/Markdown/RTF; existing pinned HTML extraction supplies semantic
web blocks. DRM-free EPUB 2/3 intake uses ZIPFoundation, Foundation XMLParser and
the existing SwiftSoup semantic conversion. It does not replace PDF handling. PDFKit text is preferred when usable. Scanned or unusable PDF pages use
bounded rendering and Vision RecognizeDocumentsRequest with structured paragraphs,
lists and tables; structures replace their child text once, avoiding double reads.
Mixed PDFs can use text and OCR on different pages. Complex reading order and OCR
accuracy still require comparison with the actual document.

Blocks retain page, EPUB archive resource path and authored/OCR/generated provenance. Footnote references and
omission notices survive the semantic boundary. Narration resolves known local
notes at their reference by default, retains unresolved/unreferenced notices conservatively,
and announces consecutive unavailable-table/code runs once. Clearly structured
numeric tables read labelled entries; verbose insets read as general prose with
captions and local placement. Complex display equations produce one original-text
reference notice per document, retaining all source ranges. See [scientific narration](SCIENTIFIC_NARRATION.md)
for scope, limits and optional image-table recognition. Source prose is not
silently deduplicated. VoiceRelay retains title/source and article-ending cues;
Libro retains its document/batch workflow.

Preparation progress identifies file/structure work, page extraction/native-layout measurement/rendering/OCR,
a separate image review/description pass, planning and phonemization. A page bar
measures the current pass; unavailable totals use indeterminate progress. Speech
counts become final only after prepared utterances exist. Cancellation and stale
updates must not overwrite the next job or phase.

## Libro interactive previews

Libro opens PDF narration/source previews after the first `ceil(pageCount × 5%)`
pages, capped at five pages and at least one. It then publishes doubling prefixes
from the same ongoing extraction, before optional image descriptions finish.
Coordinated file opening still precedes the first update; scanned first pages still
need OCR. Empty/unnarratable leading prefixes wait for readable content. Each
checkpoint is awaited, so planning cannot accumulate a backlog of UI updates.
All page/OCR/text/layout limits remain cumulative across checkpoints.

The sheet observes live preview state, uses a hidden-label segmented control and
lazy, flexible scrolling passages; analysis notes expand separately instead of
displacing narration. Rows say **Analyzing text** and partial previews show actual
available-page counts. Recurring margins, page-seam joins, optional image captions
and Contents can change at later checkpoints, so partial results are clearly
labeled. The final update uses the normal complete semantic document and planner.
Generation does not consume partial previews and retains its existing behavior.

Done/Escape/dismissal cancels the owned analysis; late updates cannot reopen it.
New imports join a cancelled preview task before using its resources. Cancellation
or a later failure leaves an already-visible prefix labeled incomplete, never
complete. Actual large-book layout/scrolling and first-page latency remain operator
L20 checks in [the consolidated checklist](OPERATOR_VALIDATION.md).

## Article title recovery

`DocumentTitles` provides shared title-quality checks, conservative opening
headline recovery and optional on-device Foundation Models generation. A title
matching either source/redirect filename is a weak candidate, even with different
case, punctuation, percent encoding or `.pdf` spelling. A weak title is retained
if no reliable richer candidate is found. Original blocks and mappings stay intact.
VoiceRelay owns Reading List candidate selection, opt-in preferences, persisted
title provenance, queue editing and display metadata; Libro's title policy is
unchanged. See [VoiceRelay source handling](../VoiceRelay/docs/SOURCE_REVIEW.md#title-recovery)
for bounds, cancellation and snapshot behavior.

## Paragraphs and conservative PDF flow

Plain text preserves explicit blank-line paragraphs and exact decoded separators;
individual newlines stay in their paragraph. Markdown/HTML/EPUB keep authored
structure. Common mapped spoken text removes discretionary soft hyphens inside
words; authored hard hyphens and numeric references stay intact.

PDFKit line ranges/crop/rotation bounds and existing Vision paragraph bounds are
retained only within fixed budgets. PDF source blocks retain native line breaks.
Unreconciled/out-of-budget geometry keeps its text and a review warning. Known
book-title/author/headings and sequential decimal folios may be omitted only with
comparable margin geometry, body separation and repeated distinct-page evidence.
Isolated recurring margin labels also qualify in local chapter runs; legal/contact
notices and uncertain cases remain. Source omission records
retain the page, block/range and reason; both apps expose planner notices.

Compatible adjacent upright single-column page runs may continue with multiple
source spans. Captions/structures, chapter/quote/list boundaries, uncertain columns,
OCR paragraph-only evidence and EPUB resources prevent joins. Supported two-column
gutter/band reconstruction changes only the spoken projection; ambiguous layouts
retain native order. Optional map/evidence budget
exhaustion retains affected text; mandatory intake budgets remain enforced. Old
snapshots lacking geometry are preserved without refetching or re-extraction.
See [implemented scope and evidence](TEXT_PROCESSING_IMPROVEMENT_PLAN.md#delivery-b-paragraph-and-pdf-flow-evidence)
and operator B06 before accepting actual-document quality.

**Join split words in PDFs (experimental)** in Libro Settings → Document or
VoiceRelay General → Document Narration optionally joins
printed `particu-` / `larly` into `particularly`, before captured pronunciation
rules and native G2P, for both Kokoro and Soprano. It defaults off, including when
decoding old settings. The native adaptation of Readium proposal #877 uses verified
upright digital PDF lines, compatible columns and a lowercase continuation.
Explicit paragraph gaps, headings, code/identifiers, OCR, uncertain geometry and
excluded sections prevent repairs. Page seams additionally require compatible
page edges and a sentence spanning the seam; joined groups stop at four pages or
200 line fragments. A cap or excluded continuation retains the boundary hyphen.
Original PDF bytes/blocks remain intact; zero-length spoken mappings retain each
removed source span and preview notices report repairs. Old snapshots are not
refetched and completed recordings are not regenerated.

English dictionary checks now preserve recognized compound hyphens (`well-` /
`known` becomes `well-known`) and leave unknown words unchanged. Local line evidence
also supports within-column joins on multi-column pages. The platform spelling
service provides validation; there is no new model, external dictionary or Readium
runtime dependency. Review and listen before using it for a book. See the
[adaptation and source provenance](TEXT_NORMALIZATION_RESEARCH.md#readium-adaptation-implemented-october-17-2026).

## Text encodings

Text and Markdown share a non-lossy Foundation decoder. Automatic mode prefers
Unicode BOMs, clear BOM-less UTF-16 byte patterns and valid UTF-8, then uses native
legacy-encoding detection. Inferred encodings produce a preview warning. Supported
explicit choices include Windows-1252, Mac Roman, ISO Latin 1, DOS 437, Shift JIS,
Windows-1251 and UTF-8/UTF-16. Binary/control-filled input and incomplete marked
Unicode fail explicitly; an old DOS EOF marker is not narrated.

Historical code pages are ambiguous. In Libro, right-click a text/Markdown row,
choose **Text Encoding**, and preview accents and punctuation before generation.
The choice follows that imported row through rescans and is captured with its
batch; it is not a global preference or an on-disk file conversion. Changing it
invalidates the preview. Active work and finished recordings are preserved; Queue
Again is required before changing a finished item. RTF keeps its native rich-text
reader and its own embedded encoding declarations.

## DRM-free EPUB books

Intake accepts both ZIP EPUB files and unpacked `.epub` folders as one book,
including through folder scans. Unpacked resources are bounded and normalized to
an in-memory ZIP with the existing ZIPFoundation implementation; the same spine,
reference, DRM, text and cover validation then applies. Resource links/aliases are
rejected, cancellation and byte/entry budgets remain enforced, and source files
are never repacked on disk. Stable entry order/timestamps keep repeated reads
consistent. Malformed packages report a book error instead of importing children.

Open, folder intake, Finder opening and drag/drop recognize `.epub` in Libro.
The package reader follows OCF container/package metadata and the **spine**, not
ZIP listing, filenames or table-of-contents order. EPUB 3 navigation does not
require an EPUB 2 NCX file. Title/creator, headings, paragraphs, lists, quotes,
notes, tables/code and authored image descriptions enter the existing semantic
pipeline. Note anchors are scoped to their archive resource so repeated IDs in
different chapters do not collide. Explicit links may load note definitions from
non-spine XHTML; unrelated auxiliary prose is not appended. Declared auxiliary
spine sections are retained in order with a review notice.

Archive resources stay in bounded memory; nothing is unpacked to disk and book
references cannot fetch a URL. Reads verify CRCs, reject unsafe paths/symlinks and
bound entries, aggregate expanded bytes, per-resource bytes, text and sections.
Defaults are 20,000 entries, 512 MB expanded/input, 32 MB per resource/text and
5,000 sections; XML metadata also has depth/node/4 MB limits. Malformed, missing,
unsupported or over-budget reading-order content fails rather than becoming a
partial successful narration. Cancellation is checked during reads and sections.
Encryption/protected content is rejected; standard font obfuscation is allowed
because fonts are not used for text extraction. No DRM removal is provided.

Embedded images reuse authored ALT/captions and shared byte/URL/caption dedup.
Optional local descriptions read only declared embedded image resources, at most
20 resources, 2 MB each and 16 MB total. External images remain inert; authored
ALT survives. SVG accessible text and available XHTML/SVG manifest fallbacks are
supported, with a fixed-layout reading-order warning. This is a narration reader,
not a visual EPUB renderer: media overlays, scripts and fixed-layout page OCR are
not implemented; image-only content without readable text/descriptions fails.
Reading-order and description quality remain operator checks.

Preparation reports EPUB structure and measured section counts (including any
referenced note resources). It does not infer an overall synthesis percentage
from these extraction counts. PDF page/OCR counts remain phase-based; native layout measurement has its own label.

## Images, captions and deduplication

Authored web/EPUB ALT and tagged PDF Figure/Alt take precedence over generated text.
Decorative/empty ALT images stay decorative. Conservative caption/credit, URL and
image-byte deduplication avoids repeated descriptions while preserving distinct
figures, distinct captions and ordinary body prose. Original blocks/provenance
remain available in the preview.

When enabled and available, on-device Foundation Models can produce a brief factual
image description. Work is bounded and joins the shared inference lease. There is
no cloud fallback or automatic model download. Web image retrieval is supplied by
VoiceRelay's bounded, public HTTPS, credential-free transport; local PDF imagery
and embedded EPUB imagery stay local. Untagged PDF page imagery is not assumed to be isolated figure geometry.

The description preference defaults on; disabling it preserves authored text and
OCR. Unavailable/refused/failed imagery must leave source text usable. Generated
descriptions are labeled and may be inaccurate. Exact-caption quality and dedup
behavior are operator gates in the [single checklist](OPERATOR_VALIDATION.md).

## Integration and further work

Apps use the same semantic/prepared-speech boundary; avoid another parser, G2P pass
or app-owned normalization algorithm. Shared dictionary rules are captured once
for the owning job. Kokoro's mapped quantity/temperature/AM-PM spoken forms and remaining pronunciation
limitations are in [the research record](TEXT_NORMALIZATION_RESEARCH.md). Automatic
changes remain in NarrationCore, after captured overrides and before native G2P;
no second encoding detector or document parser is added. Libro and VoiceRelay
previews display aggregated change notices, using the captured voice/dictionary.
App-specific source/recovery behavior is in
[VoiceRelay's source guide](../VoiceRelay/docs/SOURCE_REVIEW.md).

## Authored outlines, covers and narration choices

EPUB 3 nav and EPUB 2 NCX are optional navigation metadata over the retained spine;
linked non-spine chapters are never appended. Resource/fragment destinations map
to source anchors. PDFKit bookmarks retain page precision, while actual
HTML/Markdown headings provide a fallback. Invalid/unresolved destinations are
unavailable instead of guessed; oversized optional trees abstain with a warning.
Contents in either app's preview navigates original source, not generated chapter
files. Cover discovery is separate from narration: EPUB 3 `cover-image` and EPUB 2
cover metadata take precedence, followed by a declared guide cover page and the
first spine page's largest plausible embedded JPEG/PNG. SVG wrappers can reference
an internal raster image; pure vector SVG rendering is not added. References must
remain inside the archive and match its manifest; scripts, external resources and
later-chapter illustrations are never fetched/searched for artwork.

PDF covers render only the first page's authored crop box/orientation through
CoreGraphics, capped at a 1200-pixel edge. The complete page design is retained;
uniformly blank/locked/unreadable pages yield no automatic art. There is no OCR,
generative image model, semantic claim that a first-page thumbnail is an authored
cover, or automatic square crop. Libro performs discovery off the UI actor with
owned cancellation/join, best-effort per-document failure, explicit selection
precedence and persisted per-document removal opt-outs. Existing source prose,
spine/narration order, manual cover choices, non-artwork preferences and completed
recordings stay unchanged.

Optional **Strip inline citations** and **Strip endnote citations** follow Footnotes
at the same level as the other narration controls. They default off, operate on
the spoken projection
and retain omitted spans/reasons; explanatory notes and uncertain references remain.
See [citation, column and typography rules](DOCUMENT_CLEANUP.md).

The shared **Footnotes** setting supports **Read with the text**,
**Read at the end** and **Do not read**. **Read appendices and extra sections**
applies only to explicit appendix/auxiliary semantics;
a non-linear EPUB spine flag alone does not authorize discarding content.
Bibliography markup is retained separately from note definitions. Repeated headings
are omitted only locally with matching structural/source evidence; equal wording
across chapters or distinct anchors remains. All new omissions retain source spans
and reasons in narration previews; source blocks and source order stay intact.
