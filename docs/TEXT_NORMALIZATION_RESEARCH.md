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
