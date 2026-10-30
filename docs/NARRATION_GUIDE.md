# Narration settings and document quality

Use this guide when a document sounds different from what you expected. Start
with the app guides for [Libro](../Libro/README.md) or
[VoiceRelay](../VoiceRelay/docs/USER_GUIDE.md).

## Where to change settings

| Choice | Libro | VoiceRelay |
| --- | --- | --- |
| Model, voice and speed | Main window with Download when missing; Settings → Models owns sizes/deletion/storage | Settings → Voice Model; Downloaded models owns sizes/deletion/storage |
| Footnotes, citations, extra sections and PDF word joining | Settings → Document | Settings → General → Document Narration |
| Image descriptions | Settings → Document | Settings → General → Narration |
| Word/name pronunciation | Settings → Pronunciation | Settings → Pronunciation |
| Cover art | Select documents → Cover Art | Settings → Publishing → Podcast Cover |

Document and voice choices apply to new previews/future batches in Libro and
newly admitted work in VoiceRelay. Pronunciation rules are captured for the owning
narration operation; see the pronunciation reference for the per-app boundary. A running batch or queued article retains its captured choices.
Changing settings does not rewrite original files or completed recordings.

## Listen to the right kind of preview

**Play Sample** plays a preset's bundled English recording at its recorded 1.0×
speed without installing a model or applying pronunciation edits. Non-English
Qwen selections and imported reference voices instead generate a live sample
with the installed model. See [model selection](MODEL_SELECTION.md) for the
speed/quality meters, complete presets and reference-recording requirements.

**Play** in Pronunciation generates a short live preview with the selected settings.
Install the required model first and stop other speech work in that app. Editing a
row, changing voice or leaving the pane stops its preview. See the
[pronunciation guide](PRONUNCIATION.md) for matching rules, automatic saving and
cross-app edit conflicts.

Kokoro defaults to Heart at 1.0×. Voice and speed are preferences, not general fixes
for extraction errors or context-dependent words such as “read” and “lead”. A
pronunciation override changes every matching whole word/phrase; it cannot choose
a different reading from sentence context.

## Choose what is read

| Setting | Default | Scope |
| --- | --- | --- |
| Footnotes | Read with the text | Identified footnotes/endnotes; alternatively read at the end or omit |
| Read appendices and extra sections | On | Sections explicitly identified as auxiliary |
| Strip inline citations | Off | Recognized author–year references and numbered citations backed by a reference list |
| Strip endnote citations | Off | Identified bibliographies and citation-only notes; explanatory notes stay |
| Join split words in PDFs (experimental) | Off | Verified digital-PDF line wraps with English dictionary evidence |
| Image descriptions | On | Available generated descriptions; authored ALT/captions and OCR remain when off |

Unmarked or uncertain text stays included. Turning off extra sections does not
remove every passage that looks like an appendix. Turning off Footnotes does not
reliably remove plain, unmarked footer text. Use Narration and its notices to see
what changed, and Original Source to inspect retained text.

## PDF analysis and split words

Libro shows a readable PDF preview early while analysis continues. The initial
page target is rounded-up 5%, capped at five pages; a scanned or empty opening may
still take time. Closing the preview cancels remaining analysis. Partial results
are provisional, and generation always analyzes the complete document.

Selectable PDF text is preferred. Unusable/scanned pages can use local OCR.
Supported repeated headers/page numbers and columns are handled conservatively;
ambiguous, rotated or irregular layouts may retain their extracted order. Neither
a successful preview nor a completed recording proves that OCR or reading order
is correct.

Experimental word joining can turn `inter-` followed on the next line by
`national` into `international`. Recognized compounds keep their hyphen, such as
`well-known`. Unknown words, uncertain geometry and unsupported OCR cases stay
unchanged. The option does not repair arbitrary spelling errors or rewrite the PDF.
Check names, compounds and page/column boundaries before using it for a long book.

## Scientific text, tables and images

Simple, verified PDF equations can receive spoken forms. Detected complex display
math receives one notice directing you to the original text per document; the
source ranges remain available. Unrecognized math can still be read imperfectly.
Advanced mathematical transcription is not implemented.

Prose-heavy tables are read as text with their captions. Numeric tables need
reliable labels; uncertain structures receive source-reference cues rather than
guessed values. Image-table OCR can misread signs, exponents or units. Keep the
original open for scientific material. [Scientific narration](SCIENTIFIC_NARRATION.md)
describes the supported rules and limits.

Authored image descriptions and captions take precedence. Available on-device
Apple Intelligence may add a brief description; generated descriptions are labelled
and can be wrong. There is no cloud fallback. Turning the option off keeps authored
image text and OCR. Cover artwork, narrated image descriptions and VoiceRelay's
external episode pictures are separate features.

## Audio and preservation

Libro exports WAV, M4A, M4B or MP3. VoiceRelay publishes mono AAC-LC/M4A at
64 kbps/24 kHz. These apps do not normalize volume, add gain, limit peaks or apply
dynamic range compression. Lossy encoding and sample-rate conversion are distinct
from level adjustment; WAV retains original Float32 samples at the model rate.

A cover choice changes artwork for future output, not existing audio. Preview
Contents uses authored document navigation; it does not create audiobook chapters.
No DRM removal, universal PDF layout correction or automatic homograph correction
is provided.

## More detail

[Document extraction and mappings](DOCUMENT_PROCESSING.md),
[citation and layout rules](DOCUMENT_CLEANUP.md),
[pronunciation matching/storage](PRONUNCIATION.md) and
[audio contracts](ARCHITECTURE.md#audio) provide the implementation-level detail.
Manual quality checks remain in the [operator checklist](OPERATOR_VALIDATION.md);
use private aliases when reporting document problems.

## Experimental phrasing and passage review

All models in both apps use semantic phrasing. Both also provide scoped
pronunciation rules and optional private retention for checking/regenerating
individual passages. Review never replaces published recordings or derives
podcast word timings from recognition. Start with [long-form quality](LONGFORM_QUALITY.md)
for the controls, storage/privacy limits and blind listening procedure.
