# Spoken-text normalization and Kokoro pronunciation

Research and decision record, October 15, 2026. This concerns written-to-spoken
text only. Audio levels and dynamics are never normalized or modified.

Current update: [Delivery A](TEXT_PROCESSING_IMPROVEMENT_PLAN.md#delivery-a-evidence)
implements the narrow source-mapped kilogram, temperature and explicit-AM/PM
increment below. Native US/GB reference checks pass; operator listening/preview
feedback accepted the improvement and the corrected letter A. Unreported app
preview acceptance remains separate. The raw frontend findings show why projection
corrections are needed. Soprano and contextual homographs remain unchanged.

## Accepted baseline

The operator selected Heart (`af_heart`) at 1.0× with
`phoneme-200-pauses-candidate-1`: actual supported phoneme packing, soft target
200, hard maximum 510, reference style-row selection and exact-zero structural
pause assembly. The existing identifier is retained so the listening evidence,
prepared records and recovery fingerprints keep referring to the same behavior.
The default changes for new settings; explicitly stored speeds and admitted jobs
remain intact. Soprano retains its native text frontend.

The saved A/B map confirms Heart Pair 4 B, Michael Pair 7 B / Pair 8 B and Emma
Pair 11 B. The prose ratings misidentify two mapped choices: Pair 9 A is the
captured baseline, and Pair 12 B is 1.1×. These do not override the operator's
explicit final choice of the pause profile at 1.0×. Listening establishes a
preferred cadence in this corpus, not universal lexical correctness. Reported
`kg`, temperatures, time phrasing and contextual `lead`/`read` remain regressions
to investigate. Footnote placement is a semantic narration setting, separate from
phonemization and inserted pauses; check its selected policy in the preview.

## Published practice and existing implementation

1. **Separate normalization, G2P and synthesis.** NVIDIA describes normalization as
   selecting spoken forms for numbers, dates, measures and similar spans, with
   contextual disambiguation for ambiguous inputs. Its grammars and contextual
   models are useful references; the Python/Pynini deployment is not a direct fit
   for our native Swift requirement. Do not replace the entire pipeline with a
   custom universal normalizer.
   [NVIDIA overview](https://developer.nvidia.com/blog/text-normalization-and-inverse-text-normalization-with-nvidia-nemo/),
   [NeMo Text Processing installation and dependencies](https://github.com/NVIDIA/NeMo-text-processing).
2. **Reuse locale-aware number spelling.** Apple's NumberFormatter spellOut
   produces words using an explicit locale. Our native port already uses this for
   cardinals/decimals, alongside model-specific currency/year/ordinal handling.
   Avoid spelling every numeric substring globally: prices, dates, identifiers,
   times and versions have different intended readings.
   [Apple spellOut](https://developer.apple.com/documentation/foundation/numberformatter/style/spellout).
3. **Reuse unit names while preserving quantities.** MeasurementFormatter with
   long unit style and providedUnit is a promising source of inflected unit names;
   the formatter is not a prose measurement parser. A local native probe on this
   SDK returned `2.4 kilograms`, `1 kilogram`, `18 degrees Celsius` and
   `-4 degrees Fahrenheit` in both en_US and en_GB. It did not spell the quantities;
   they can proceed through the existing number frontend. Explicit providedUnit
   avoids accidental Fahrenheit/Celsius or kilogram/pound conversion.
   [Apple MeasurementFormatter](https://developer.apple.com/documentation/foundation/measurementformatter),
   [unit options](https://developer.apple.com/documentation/foundation/measurementformatter/unitoptions).
4. **Keep pronunciation model-specific.** Misaki combines dictionaries, rules and
   an out-of-dictionary fallback. Its phoneme alphabet has regional differences
   and is a model input contract, not arbitrary IPA. Preserve the pinned US/GB
   resources, strict vocabulary validation and one G2P pass; do not mix another
   engine's phonemes into Kokoro.
   [Misaki](https://github.com/hexgrad/misaki),
   [phoneme contract](https://github.com/hexgrad/misaki/blob/main/EN_PHONES.md).
5. **Respect context and honest limits.** Kokoro's author explicitly discusses the
   limits of dictionary-only pronunciation for homographs. Apple lexicalClass
   provides part-of-speech evidence, not guaranteed semantic or tense resolution.
   A global `lead → leed` or `read → red` substitution would corrupt valid prose.
   Our existing longest-first user spelling dictionary is the explicit correction
   mechanism; it remains captured once per job and visible in projection metadata.
   [Author's G2P discussion](https://huggingface.co/blog/hexgrad/g2p),
   [Apple lexical classes](https://developer.apple.com/documentation/naturallanguage/nltagscheme/lexicalclass).
6. **Keep acoustic constraints separate from normalization.** Upstream Kokoro
   bounds English phoneme input at 510 and selects voice style using length minus
   one. Our smaller 200-token packing target and structural timings are empirical
   choices accepted through this project's listening, not published universal
   optimums. Changes to those choices require new comparison evidence.
   [Kokoro reference pipeline](https://github.com/hexgrad/kokoro/blob/main/kokoro/pipeline.py).

## Native diagnostic confirmation

The archived Libro worker was also checked offline with six short synthetic
passages in US and British mode (12 prepared outputs), retained privately under
`.build/longform/accepted/normalization-diagnostics/frontend.json`. These checks
record actual prepared phonemes; they are not an ASR or listening acceptance gate.

- US `2.4 kg` retained the number but produced `kˈɛɡ` for the unit; the British
  output also did not spell out kilograms.
- `18°C` produced an incorrect word-like phoneme sequence in both locales,
  omitting the intended numeric/temperature reading. The passing decimal/currency
  fixtures do not cover this combined numeric-unit form.
- `9:30 am` retained the colon in its phoneme input, a plausible contributor to
  the reported time-reading pause; that acoustic cause remains an inference.
- The two `lead` occurrences and the past/present `read` occurrences had identical
  pronunciations within each locale. The two `wind` occurrences differed correctly.

This confirms frontend limitations independent of the selected voice's timbre.
The current strict vocabulary checks establish supported model input, not semantic
correctness of every pronunciation. These are the first required regression cases
for the follow-up below, rather than claims that the accepted pacing fixed them.

## Recommended next normalization increment

Keep the accepted acoustic profile fixed while evaluating a narrow, versioned
spoken-projection normalization stage in NarrationCore. Use Foundation formatters
for rendering recognized quantities and NaturalLanguage for sentence/token
boundaries; retain model-specific G2P, POS adaptation and vocabulary in the helper.
No new package is justified for this bounded shared responsibility. Enable the
first normalization increment for Kokoro; evaluate Soprano independently before
changing its accepted text path.

- Start with explicit number-plus-unit forms from the reported failures:
  `2.4 kg`, `1 kg`, `18°C`, `-4 °F`, then unambiguous time forms such as `9:30 am`.
  Test absent spaces, Unicode minus, punctuation, singular/plural and both locales.
  Match whole quantities with strict token/context boundaries; never replace every
  occurrence of `m`, `in`, `C`, `F` or a substring in an identifier/URL/code block.
- Retain source prose and block provenance. Record every spoken replacement with
  before/after UTF-16 ranges and rule/version identifiers, expose changes in
  narration previews, and feed exactly that projection into G2P once. Bound
  replacement expansion and mapping size before IPC; no document-sized MLX buffer.
- User overrides on original words/phrases take precedence. Mark their spans as
  protected from automatic normalization, then normalize only untouched spans.
  Do not recursively interpret a user's phonetic spelling as a unit or number.
  This requires composed source mappings; the current user-rule-only mappings
  must not be mislabeled as covering automatic expansions.
- Keep decimal/currency parsing in its existing frontend unless a fixture proves
  it needs moving; avoid duplicate expansion. Dates like `1/4`, version numbers
  and ambiguous abbreviations should remain conservative until context or an
  explicit user override resolves them. Preserve punctuation and diacritics.
- For homographs, first inspect actual aligned native phonemes and Apple's tags
  against pinned Misaki behavior; apply demonstrated port fixes rather than an
  unbounded exception list. Do not add generative rewriting or Apple Intelligence
  as an automatic pronunciation fallback. A future contextual model needs its
  own bounded, offline evaluation and abstention behavior.
- Give normalization its own version in semantic/acoustic provenance and checkpoint
  compatibility. Retain already placed/published audio. Reprepare unfinished work
  through the existing safe replacement path; do not invalidate finished media.

Acceptance: exact spoken-projection cases and adversarial nonmatches; source/rule
mapping and override precedence; US/GB native phonemes; no omissions/duplication;
Heart/Michael/Emma matched 1.0× listening of only the changed cases; original
Float32 fidelity, AAC 64 kbps/24 kHz and separate coordinator/helper memory checks.
The native formatter probe establishes API behavior, not successful prose parsing
or a listening result. The earlier acoustic-baseline activation did not include these corrections.
Delivery A now implements the narrow deterministic increment; homograph policy
remains deferred, and listening acceptance stays separate from automated evidence.


## Letter A labels: operator follow-up

The Delivery A listener reported that every tested voice read “Package A” as an
article. Offline native US/GB preparation reproduced `ɐ` for “Package A” and
“Plan A”; the existing lexicon returns the intended stressed `ˈA` for “ay”.
This is a text-tagger ambiguity before synthesis, shared across these voices.

`spoken-forms-2` projects only standalone capital A after explicit label contexts:
package, plan, option, appendix, section, figure, table, part, group, class, type,
grade, vitamin and letter. The spoken spelling is “ay”; the original A and its
source range survive. Ordinary lowercase articles and sentence-initial “A car”
are untouched. Unsupported/ambiguous contexts abstain. Code, identifiers,
equations, unverified sources and captured user overrides retain their protections.
The model/frontend pins, other letters, Soprano and audio levels are unchanged.
Exact US/GB phonemes are regression evidence; corrected audio requires listening.


The user subsequently confirmed the letter-A correction as fixed and authorized
Delivery B. Common `text-flow-1` now handles explicit paragraphs, mapped soft
hyphens and conservative native PDF flow; see the current implementation checklist.
It does not enable additional model-specific homograph or lexical substitutions.

## PDF printed-word dehyphenation: library-first investigation

Research requested October 17, 2026. The initial library-first findings below led
to the authorized optional Readium adaptation recorded at the end of this section.
No library/model was installed or dependency pin changed.

### Baseline behavior (option off)

`SpokenFormNormalizer` removes **U+00AD soft hyphens** in mapped spoken text.
It does not remove ASCII `-` (U+002D) or typographic U+2010 hard hyphens at printed
line endings. `PDFContinuationTests.testOnlyExplicitDiscretionaryWordSplitIsRepairedAcrossPages`
explicitly retains the hard-hyphen boundary. Whitespace normalization can therefore
leave a printed `inter-` / `national` as `inter- national`, unlike the soft-hyphen
case. This is consistent with the reported pronunciation interruption, but the
operator's actual PDF/code points have not been inspected.

The earlier preservation policy was deliberate: geometry alone cannot distinguish
`extraor-` / `dinary` from `well-` / `known` or ambiguous `re-` / `creation`.
Any correction belongs before G2P in the source-mapped spoken projection, not in
audio post-processing or by rewriting original PDF/source blocks.

### Existing implementations and native fit

| Candidate | Evidence and fit | Limitations / decision |
| --- | --- | --- |
| MuPDF C structured-text extraction | Official `FZ_STEXT_DEHYPHENATE` records line-ending hyphens as soft hyphens and joins lines when flattened. PyMuPDF exposes the same family of behavior as `TEXT_DEHYPHENATE`. A native C integration does not require Python. | Strongest established extractor-level option. MuPDF is AGPL or commercially licensed; redistribution review is required. It is a second PDF extraction stack, not a drop-in PDFKit postprocessor, and remapping extraction order/characters to existing source provenance needs evaluation. The flag is not proof of linguistic correctness for authored compounds. |
| PDFium C API | Public `FPDFText_IsHyphen` is marked experimental; the upstream text-page implementation classifies hyphen boundaries using line geometry and adjacent characters. Native C API; core license has BSD-style terms, with bundled/transitive notices to review. | Useful existing extraction signal, not an English word/compound disambiguator. Replacing/adding a large PDF backend and its build graph solely for this issue is not justified without measured wins. |
| Readium Swift toolkit | BSD-3-Clause source. Its content API has semantic elements/locators. Proposal #877 directly targets broken PDF/FXL TTS, joining printed fragments while preserving per-fragment page locators and bounded sentence regions. | Closest Swift architectural precedent. Read-only GitHub API/source verification on October 17 confirms open/draft, unmerged, head `3a50f066f0b050f2951c211b41cf69d8eab9be6a`. This is draft behavior, not a shipped release guarantee. Adapt its bounded joining pattern without adding its reader or speech engine. |
| `pd3f/dehyphen` | Purpose-built dehyphenation using Flair character-language-model perplexity to compare alternative joins; handles preserving some genuine hyphens rather than only deletion. | Python/GPLv3 and additional neural-model assets. Not an acceptable product runtime under the native/no-new-model constraints. A useful reference for why context matters, not an installation recommendation. |
| calibre heuristic processing | Official conversion documentation describes unwrap/dehyphenation heuristics and using the document itself as a dictionary to decide whether hyphens are retained. | Mature reference, but heuristic conversion may worsen some documents and operates on converted text/structure. Not a native Swift drop-in; no calibre/product CLI integration is proposed. Same-document repeated unsplit forms are useful evidence to evaluate. |
| Swift `Hyphenation` / Apple's CFString hyphenation APIs | Swift library implements Knuth-Liang layout hyphenation; its documented `unhyphenate` removes separator characters. Apple's API returns possible hyphenation locations for a known word and locale. | **Not inverse PDF dehyphenation.** Removing every `-` corrupts real compounds; layout break opportunities do not prove the intended joined spelling. CFString can provide a native corroborating signal without a dependency, but is not a complete solution. Swift library is MIT with separately licensed pattern data. |

A read-only probe on the installed macOS/SDK confirmed CFString hyphenation data
for both en_US and en_GB. Its results differ by locale: the proposed `inter-`
boundary in `international` was returned for en_GB but not en_US, while the
candidate `wellknown` admitted boundary 4 for en_US. Thus a valid layout break
location neither proves a legitimate spelling nor reliably recovers an observed
printed wrap. This probe did not alter source text or implement a repair. Ignored
output is `.local/pdf-hyphenation-apple-probe.log`.

### Initial evaluation criteria

1. Obtain a small nonprivate example from the reported failure: the two extracted
   line fragments and whether it crosses a page/column. Inspect its Unicode scalar
   and retained line evidence. No private book upload or live service is needed.
2. If a new native PDF backend/license is acceptable, evaluate MuPDF's existing
   dehyphenation against the current PDFKit extraction on synthetic fixtures
   first. Preserve unmodified extraction as the source of truth; measure mapping,
   compound handling, reading order and memory before adopting it.
3. Inspect Readium's proposed joining component once live public source access is
   available. Reuse a suitable small BSD-licensed component only after checking
   maturity, macOS compatibility and exact behavior; do not import an entire reader
   stack or replace the current speech worker merely for this.
4. If neither is suitable, evaluate existing Apple language/hyphenation facilities
   and same-document spelling evidence over the **already retained PDF line
   geometry**. Only then propose the smallest mapped joining policy. This would be
   limited integration/decision logic, not a new PDF parser or generative rewrite.
   An uncertain join must abstain or require an explicit user override.

The critical regression pairs are `inter-\\nnational` -> `international`,
`extraor-\\ndinary` -> `extraordinary`, and `well-\\nknown` -> `well-known`
(remove the line boundary without deleting an authored hyphen). Also evaluate
`state-of-\\nthe-art`, ambiguous `re-\\ncreation` / `re-\\nsign`, proper names,
US/GB variants, numeric minus/ranges, URLs/identifiers, dialog dashes, heading/
column/page boundaries, OCR uncertainty, Unicode/combining marks, overrides and
bounded UTF-16 source maps. These are proposed evaluation cases, not regenerated
current goldens. Original prose, completed audio, worker count, audio levels and
the accepted acoustic policy must remain unchanged.

### Readium adaptation implemented October 17, 2026

The operator authorized trying the draft's approach. `PDFWordJoining.swift`
adapts its hard-hyphen/lowercase fragment rule and hard-break classification into
the existing PDFKit layout and UTF-16 projection pipeline. The exact upstream
`SentenceRegionBuilder.swift` was fetched again during resumption and matched the
earlier inspected copy (SHA-256
`c8a9d84010b551793867cde67bc467a09e2ce6f54d2bc3d359d3a7f4085bea64`).
The original license and adaptation details are retained in
[Readium notices](../swift-packages/ThirdPartyNotices/Readium/README.md).

`NarrationOptions.experimentalPDFWordJoining` defaults false, is omitted when
encoding false for legacy identity compatibility, and is exposed by both apps'
existing Document Narration controls. Enabling it versions the semantic plan;
identical spoken text retains compatible acoustic fingerprints. Captured job
settings own the choice. There is no implicit old-snapshot extraction or completed
recording regeneration.

Within one authored digital PDF paragraph, a verified ASCII/U+2010 trailing hyphen
and one newline before lowercase text can be removed from speech. Geometry must
support a consistent upright column and nearby lines. Paragraph gaps, hard breaks,
code/paths/identifiers, unsupported geometry, OCR and non-PDF resources abstain.
Across adjacent pages, compatible page edges/columns and a native sentence bridge
are additionally required. Groups are bounded to four pages and 200 fragments;
the boundary hyphen stays if a seam cannot be joined. Layout analysis respects
structurally excluded sections, so omitting an auxiliary continuation cannot cut
the preceding word. Known recurring margins compose through the existing maps.

Repairs precede captured pronunciation rules and native G2P for both engines.
Original blocks remain unchanged, mapped zero-length spoken omissions retain the
removed UTF-16 spans, and preview notices disclose the experiment. Upstream's
compound ambiguity remains: `well-` / `known` becomes `wellknown`, rather than
meeting the initial ideal compound-preservation criterion. This is why the option
is explicit and off by default; no dictionary/model guess is silently added.

Focused and native evidence is maintained in
[current status](IMPLEMENTATION_STATUS.md); actual-document and matched listening
remain [operator B07](OPERATOR_VALIDATION.md). The broader Readium iterator,
sentence/search/locator service and EPUB FXL integration are outside this increment.

### Primary sources consulted

- [MuPDF C structured-text flags](https://mupdf.readthedocs.io/en/latest/_static/generated/c/html/structured-text_8h.html)
- [MuPDF license](https://mupdf.readthedocs.io/en/latest/license.html)
- [PyMuPDF text-extraction flags](https://pymupdf.readthedocs.io/en/latest/vars.html)
- [PDFium public text API](https://pdfium.googlesource.com/pdfium/+/refs/heads/main/public/fpdf_text.h)
- [PDFium text-page implementation](https://pdfium.googlesource.com/pdfium/+/refs/heads/main/core/fpdftext/cpdf_textpage.cpp)
- [PDFium license](https://pdfium.googlesource.com/pdfium/+/refs/heads/main/LICENSE)
- [Readium content API](https://readium.org/swift-toolkit/3.8.0/documentation/readium/content/)
- [Readium fixed-layout TTS proposal #877](https://github.com/readium/swift-toolkit/pull/877)
- [Readium license](https://github.com/readium/swift-toolkit/blob/develop/LICENSE)
- [dehyphen project documentation](https://pd3f.com/docs/dehyphen/)
- [calibre heuristic processing](https://manual.calibre-ebook.com/conversion.html#heuristic-processing)
- [Swift Hyphenator API and separator-removal warning](https://john-mueller.github.io/Hyphenation/Classes/Hyphenator.html)
- [Swift Hyphenation licensing/pattern data](https://john-mueller.github.io/Hyphenation/)
- [Apple CFString hyphenation API purpose](https://developer.apple.com/library/archive/releasenotes/CoreFoundation/RN-CoreFoundation-iOS/CoreFoundation_iOS5.html)
- [Apple PDFSelection string semantics](https://developer.apple.com/documentation/pdfkit/pdfselection)
