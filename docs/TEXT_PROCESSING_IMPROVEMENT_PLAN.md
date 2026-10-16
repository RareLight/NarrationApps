# Text processing improvement plan

October 15, 2026. **Delivery A listening, including the letter-A correction, is
operator accepted. The user authorized the next stages; Delivery B (TP4–TP7) is
implemented within the conservative scope below and awaits operator validation.**

Based on the [normalization research](TEXT_NORMALIZATION_RESEARCH.md) and the user's
requirements: efficient code, bounded resource use, maintainability and high-quality,
source-faithful output take priority over feature breadth.

## Start gate and authority

The user explicitly authorized Delivery A in the main chat after the completed
EPUB/encoding engineering handoff and its automated evidence. EPUB manual checks
L15/L16 remain operator-owned; that authorization does not mark them passed.
Automated development/testing is authorized for shared, Libro and VoiceRelay.
The operator subsequently accepted the corrected listening and explicitly
authorized the next stages. This authorizes TP4–TP7; deferred features remain separate.

The baseline was shared `275b30f`, Libro `7539d2e`, VoiceRelay `d399874`, with the
uncommitted EPUB/encoding implementation, related docs/notices/resolution files and
the then-current advisory documents. These hashes alone do not
reproduce the working snapshot. No reset, commit, publication or asset download
was performed for Delivery A.

Follow each repository's AGENTS.md and the current shared
[architecture](ARCHITECTURE.md), [status](IMPLEMENTATION_STATUS.md) and
[roadmap](IMPLEMENTATION_PLAN.md). This draft elaborates proposed text work; it
does not supersede their contracts or authorize deferred features.

Current implementation belongs to the three repositories in
[the NarrationApps layout](REPOSITORY_LAYOUT.md). The original external
comparison is complete; no TextExtractor checkout or Python tooling is needed.

## Delivery boundaries

| Delivery | Steps | Outcome | Release boundary |
| --- | --- | --- | --- |
| A: spoken forms | TP0-TP3 | Verified baseline; minimal mappings; quantity/temperature and explicit-time fixes | First implementation handoff; stop for review after TP3 |
| B: document flow | TP4-TP7 | Paragraph boundaries, bounded PDF evidence, recurring margins and conservative continuation | Separate go-ahead after A; validate each step before proceeding |
| Later candidates | Deferred section | Columns, annotation scheduling, outlines or citation choices if justified | Separate scope and approval, not automatically scheduled |

Within an authorized delivery, proceed through focused automated gates without
unnecessary approvals for ordinary edits. Do not advance past a failed quality or
resource gate, an unresolved material design decision, or an operator acceptance
gate required for activation. End each delivery with evidence and remaining risks.
Keep commits/diffs coherent if commits are requested; do not commit automatically.

## Nonnegotiable design constraints

- Keep shared behavior in existing targets: DocumentProcessing for extraction/layout,
  NarrationCore for projection/contracts, Pronunciation for captured user overrides.
  ProcessingPipeline coordinates existing preparation; apps retain workflows.
- No new dependency/product/CLI, plugin system, universal normalizer, global text
  cache or standalone audit subsystem. Extend abstractions only for a demonstrated
  use in the current step; keep internal helpers internal.
- Preserve extracted source blocks, Unicode, page/resource provenance and source
  order. A semantic source artifact is not the original file's byte representation.
  Uncertain heuristic decisions leave content unchanged; invalid input/protocol
  failures remain explicit errors, never silently truncated output.
- Run overrides once, before G2P, using the captured job dictionary. Keep model-specific
  G2P/helper ownership, US/GB resources, native packing limits and accepted pacing.
  Do not change Soprano's automatic spoken-form behavior as part of Delivery A.
- Retain one speech worker and existing inference admission/Libro priority.
  Keep heavy work off MainActor, framework objects isolated, and cancellation joined.
  Do not add parallel OCR or detached tasks without owned lifetimes.
- Preserve installed preferences, private data, published/finished recordings,
  article identity/save dates and existing output/recovery safety. No live migration,
  refetch, sample regeneration, signing-account operation, packaging/install or
  publication is implied by testing this plan. Audio levels/dynamics stay unchanged.

## TP0. Reconcile the finished EPUB baseline

Purpose: avoid colliding with current development or building on stale review facts.

- [x] **TP0.1** User accepted the EPUB engineering handoff and explicitly started
  Delivery A; its test/build evidence and pending L15/L16 operator checks are recorded. Preserve any
  remaining unrelated edits; no reset, cleanup or history rewrite.
- [x] **TP0.2** Read current instructions/status, manifests, relevant implementation
  and fixtures in all affected repositories. Record baseline revisions plus dirty
  paths; review current EPUB/encoding/provenance changes before touching shared models.
- [x] **TP0.3** Autonomous testing confirmed by the user's current authorization
  and repository instructions for all three repositories. No additional testing-mode
  permission is needed; GUI/listening/protected-file/live acceptance stays manual.
- [x] **TP0.4** Check local dependency/model readiness without downloading or loading
  models. Inspect test/build scripts for network, patching, packaging and deletion
  side effects. Missing assets or required network access are setup blockers requiring
  separate authorization, not permission to update pins or reset caches.
- [x] **TP0.5** Confirm Delivery A as the initial scope, selected locales/voices and
  unchanged Soprano behavior. Reconcile overlap with any normalization work already
  completed by the main agent; reuse it instead of implementing a second path.

Gate: EPUB completion is established; current ownership, baseline, testing mode
and setup are understood. No production behavior changes in TP0.

## TP1. Establish focused quality and cost baselines

Owners: shared tests, using existing XCTest/fixture infrastructure; app tests only
for adapter behavior. No benchmark product or corpus download.

- [x] **TP1.1** Add or extend small synthetic cases for exact source/spoken text,
  source ranges, override precedence, legacy decoding and unchanged nonmatches.
  Establish expected results independently of the normalizer being tested.
  Demonstrate red regressions for reproduced defects; keep unaffected baseline
  checks green and distinguish those expected reds from unrelated failures.
- [x] **TP1.2** Include the EPUB/encoding baseline in affected regressions: spine
  order, resource-local/cross-resource notes, embedded ALT/images, protected/malformed
  input rejection and text-encoding fidelity. Keep existing parser/security limits.
- [x] **TP1.3** Create bounded, reproducible small/medium/large synthetic text and
  PDF workloads with known expected output. Include no-change prose and dense
  eligible replacements; do not use private books or the excluded Python corpus.
- [x] **TP1.4** Record optimized-build extraction, projection/mapping and frontend
  preparation costs separately. Compare identical settings/outputs; separate cold
  startup from warm work, CPU-only processing from OCR/G2P, and coordinator from helper.
- [x] **TP1.5** Choose fixture-specific time, memory, expansion and cancellation
  budgets from this baseline before enabling new rules. Record hardware/toolchain,
  workload sizes, repetitions and variability. Avoid invented universal percentages
  or brittle wall-clock assertions in ordinary tests.

Gate: expected output is independently specified and baseline results are recorded
under the selected testing mode, including expected red cases awaiting TP3.
Those reproductions are not an exception to later acceptance gates.
In manual mode, hand off exact focused commands
and obtain results rather than claiming unrun tests passed. Profiling beyond the
routine isolated workload remains explicit and proportionate.

## TP2. Add only the mapping needed for the first spoken-form rules

Starting points: [semantic contracts](../swift-packages/Sources/NarrationCore/SemanticDocument.swift),
[planner](../swift-packages/Sources/NarrationCore/NarrationPlanner.swift),
[existing ranges](../swift-packages/Sources/NarrationCore/PreparedSpeech.swift),
[windowing](../swift-packages/Sources/NarrationCore/SpeechTextWindows.swift) and
[pronunciation applications](../swift-packages/Sources/Pronunciation/PronunciationDictionary.swift).
These paths must be reconfirmed after EPUB completion.

- [x] **TP2.1** Specify block-local extracted UTF-16 coordinates separately from spoken
  UTF-16 coordinates. Existing `SpokenSourceRange` offsets describe the spoken
  projection; do not reinterpret or cosmetically rename persisted fields.
- [x] **TP2.2** Implement a small internal projection/edit representation alongside
  the first concrete rule. Map unchanged runs compactly, changed spans explicitly,
  and generated cues as generated. Support multiple origins only when a current
  transformation needs them; do not prebuild a general transformation engine.
- [x] **TP2.3** Protect original user-rule match spans from automatic interpretation.
  Compose mappings through replacements/whitespace/known marker removal; do not
  reinterpret phonetic spelling or apply the dictionary recursively. If a path
  cannot provide trustworthy mappings, conservatively skip unsupported automatic
  edits rather than fabricate original-source ranges.
- [x] **TP2.4** Account for every applied change with a bounded reason/rule/version
  record linked to source spans. Avoid per-character records and logging every
  negative match. Aggregate repeated notices; do not include private text in logs.
- [x] **TP2.5** Add tests for expansions, contractions, adjacent edits, emoji/combining
  marks, captions/generated cues, note-marker removal and chunk/window boundaries.
  Check unchanged source blocks, full projection coverage and correct composition.
- [x] **TP2.6** Give both preview and speech preparation the same transformation
  decisions from the same captured context. Preserve current text/version identity
  for the TP2 no-op path unless a demonstrated compatibility change requires otherwise.

Gate: round-trip range checks, exact coverage, Unicode safety, cancellation and
mapping budgets hold. Deliver these helpers with TP3, not as an unrelated public API.
The mapping representation must remain small relative to its input/work performed.

## TP3. Deliver narrow quantity, temperature and explicit-time corrections

Owner: NarrationCore's spoken projection; keep native G2P and existing working
decimal/currency handling in their current owner. Follow
[the existing research](TEXT_NORMALIZATION_RESEARCH.md), not Python substitutions.

- [x] **TP3.1** Define exact expected spoken forms for `2.4 kg`, `1 kg`,
  `18\u{00B0}C` and `-4 \u{00B0}F` in US/GB context (Swift escapes denote actual
  degree signs in fixtures). Exercise absent spaces, Unicode minus, decimal
  values, punctuation and singular/plural. Preserve the original quantities/units.
- [x] **TP3.2** Recognize only a bounded set of whole quantities with strict context
  boundaries. Reuse Foundation number/unit rendering with an explicit locale and
  no automatic unit conversion. Cache/reuse formatter instances only within a safe
  job/isolation scope; avoid overlapping number normalization in two layers.
- [x] **TP3.3** Keep URLs, identifiers, code, ambiguous short unit strings, user-rule
  spans, versions, equations and dates unchanged. Include adversarial nonmatches
  and a large no-change input; do not expand every `m`, `in`, `C` or `F`.
- [x] **TP3.4** After quantities pass, add a separately testable explicit-AM/PM time
  increment beginning with `9:30 am`. Fix expected speech using native frontend
  evidence; do not guess a globally correct time grammar. Leave ambiguous dates,
  24-hour forms and general colon punctuation outside the initial rule set.
- [x] **TP3.5** Compare exact projections and actual aligned US/GB native phonemes
  using installed, explicitly enabled offline fixtures. Keep strict coverage,
  vocabulary, 1,000-scalar windows and 510-token limits. Synthetic phonemes are not
  evidence that real pronunciation is correct. Confirm Soprano remains unchanged.
- [x] **TP3.6** Integrate reason notices into Libro's existing preview, which at
  drafting discards planner notices. Verify VoiceRelay's normal and source-review
  previews expose the same decisions. No new Settings pane or diagnostic subsystem.
- [x] **TP3.7** Include normalization policy/locale/rules in appropriate plan identity,
  provenance and unfinished-checkpoint compatibility. Test legacy decoding, safe
  repreparation, captured settings and preservation of already finished/published
  audio with isolated data. Do not invalidate raw acoustic identity for unrelated
  display-only metadata or change audio assembly/encoding.
- [x] **TP3.8** Run focused checks, affected app/required regression gates and both
  build-only consumer checks. Repeat the matching TP1 cost measurements; explain
  any regression. Record automated evidence separately from operator listening/UI.

Delivery A gate: exact expected output, adversarial nonmatches, source mapping,
preview parity, recovery safety and performance budgets pass. Hand off short matched
US/GB listening cases and preview checks through the consolidated operator checklist.
Do not call the changed behavior accepted until its operator gates pass.
**Stop here for review before starting Delivery B.**

## TP4. Preserve explicit paragraphs and repair discretionary wraps

Begin only after Delivery B is authorized. Owners: DocumentProcessing for source
structure; NarrationCore for mapped spoken alternatives and existing pause boundaries.

- [x] **TP4.1** Preserve explicit blank-line paragraphs in plain text before general
  whitespace collapse. Keep Markdown/HTML/EPUB authored structure; do not run PDF
  reconstruction rules on those formats or infer print wraps from every newline.
- [x] **TP4.2** Remove discretionary soft-hyphen interruptions only in mapped spoken
  text. Keep hard hyphens unless layout evidence later proves a print-wrap repair.
  Do not flatten typography/diacritics, delete replacement characters or add a
  second encoding detector.
- [x] **TP4.3** Cover CR/LF conventions, blank lines, verse, dialogue, lists, quotes,
  headings, authored compounds and literal numeric references. Assert exact retained
  source and intended paragraph/continuation boundaries; retain accepted gap durations.
- [x] **TP4.4** Apply the same preview, version/recovery and performance gates as TP3
  for this narrower change. Investigate pause-count changes rather than altering
  model speed or acoustic pacing to compensate.

Gate: explicit paragraph structure improves without unintended joins, text loss,
encoding changes or a measurable unjustified no-change-path regression.

## TP5. Prototype and retain bounded PDF layout evidence

Starting points: [PDF extraction](../swift-packages/Sources/DocumentProcessing/PDFDocumentExtractor.swift)
and [structured OCR](../swift-packages/Sources/DocumentProcessing/StructuredDocumentOCR.swift).
This is an evidence/feasibility stage, not permission to build a layout engine.

- [x] **TP5.1** Use synthetic digital/scanned/mixed PDFs to verify PDFKit line/selection
  geometry and existing Vision paragraph/structure bounds on the current SDK.
  Cover crop/media boxes and rotation; normalize coordinate conventions explicitly.
  A successful API call does not establish correct reading order.
- [x] **TP5.2** Retain only line/span/page evidence needed for margin and adjacent-prose
  decisions. Keep PDFKit/Vision objects inside extraction; pass Sendable values.
  Add persisted metadata only where a current consumer/recovery path needs it.
- [x] **TP5.3** Keep embedded usable text as the default. Do not OCR every digital
  page or introduce another PDF/parser library. If geometry cannot be reconciled
  to extracted text, keep that region unchanged and record a bounded diagnostic.
- [x] **TP5.4** Measure geometry cost and retained metadata separately. Choose a
  bounded per-page candidate summary or two-pass approach; do not retain rendered
  pages, duplicate document text, or rescan all earlier pages for each new page.
- [x] **TP5.5** Test legacy artifacts without geometry, image/caption preservation,
  mixed-page provenance, page/text/OCR budgets, failure and cancellation. Reuse
  existing inference admission; no extra worker, unbounded task group or background job.

Gate: evidence aligns with text, metadata/cost budgets hold, extraction text remains
unchanged and no additional OCR is introduced on the ordinary usable-text path.
If native evidence is insufficient, report the limitation; do not compensate with
speculative custom columns or a new dependency.

## TP6. Suppress recurring PDF margin furniture in narration

- [x] **TP6.1** Count normalized header/footer candidates by distinct page and
  comparable margin location. Support alternating-page headers and changing digits.
  Keep comparison keys separate from source Unicode/text.
- [x] **TP6.2** Require geometric and repetition evidence; calibrate thresholds with
  independent positive and adversarial fixtures. Short/uncertain documents abstain.
  Use indexed summaries, not document-wide all-pairs fuzzy comparisons.
- [x] **TP6.3** Suppress only eligible projected spans; retain originals, page origin,
  reason and visibility in both apps. Never delete prose merely for repeating,
  being short/all caps/numeric, resembling a URL or containing a legal notice.
- [x] **TP6.4** Test repeated body prose, refrains, headings, folios, tables, footnotes,
  contents/index pages and multilingual text. Confirm deterministic decisions and
  no body loss; token-retention percentages alone are not acceptance.
- [x] **TP6.5** Exercise preview/recovery behavior and TP1-scale costs. Optional
  heuristic budget exhaustion must leave affected text unchanged, not bypass intake
  limits, truncate output or silently drop diagnostic/provenance obligations.

Gate: known furniture is omitted with an inspectable reason, adversarial source
content survives, no unsupported reordering occurs, and memory/time remain bounded.

## TP7. Join only demonstrated PDF prose continuations

- [x] **TP7.1** Use TP5 evidence after TP6 margin classification to recognize compatible
  adjacent runs within a column/across pages. Preserve source block order and
  multiple source spans instead of rewriting original blocks into one string.
- [x] **TP7.2** Limit repairs to well-supported continuation/dehyphenation cases.
  Keep authored hard-hyphen compounds, and stop at headings, chapter/resource
  boundaries, lists, quotations, captions and incompatible regions. Capitalization
  or a missing period alone is insufficient evidence.
- [x] **TP7.3** Prevent known captions from being swallowed into prose. Do not introduce
  speculative annotation relocation to make a broken join appear correct; abstain
  when an intervening region makes the relationship unclear.
- [x] **TP7.4** Verify positive joins and plausible nonjoins on page/column transitions,
  compounds, short prose, figures and EPUB nonapplicability. Preserve exact source
  accounting and use existing continuation/paragraph pauses without changing timings.
- [x] **TP7.5** Repeat affected suites, both build-only integrations and matching
  extraction/projection/preparation measurements. Hand off representative PDF
  reading-flow, preview and listening acceptance; preserve old snapshots lacking
  geometry unless re-extraction is explicitly authorized.

Delivery B gate: improvements are observable without lost/reordered body content
or unacceptable resource growth. Stop and report unresolved layout limitations.

## Performance and maintainability gates

Apply these to each behavior change, not as a separate optimization project.

| Concern | Required evidence/constraint |
| --- | --- |
| Algorithmic growth | Single-pass/indexed span processing; exercise scaled workloads within existing limits to detect quadratic growth |
| Swift strings | Avoid repeated whole-prefix counts, UTF-16 conversions, substring copies and concatenation in inner loops; track offsets as scanning proceeds |
| Source maps/notices | Coalesce unchanged runs; enforce edit/expansion/metadata budgets; no per-character map or unbounded rejection log |
| Memory | Measure retained/peak CPU memory on long and replacement-dense inputs; distinguish allocator noise, coordinator and native helper |
| Expensive APIs | Measure geometry, OCR and G2P independently; no additional OCR/model inference for an ordinary text-only no-change case |
| Responsiveness | Cancellation checks at bounded work intervals; no blocking work on MainActor, per-span UI updates or stale progress |
| Output quality | Exact independently authored expectations, coverage and ordered anchors; improved speed cannot excuse omitted or corrupted content |
| Scope | Existing APIs/dependencies first; no unrelated refactoring, speculative caching, persistence service or public API |

Use optimized builds for performance conclusions, matched settings and repeated
measurements with stated variability. Separate process startup from warm operation.
Measure extraction/projection before synthesis so model latency does not hide a
cleanup regression. Do not repeatedly synthesize whole documents to benchmark
CPU text changes. Add signposts/Instruments only when measurements identify a
question they can answer.

TP1 must produce concrete workload-specific budgets; later deliveries must record
their observed deltas against them. A timing outlier triggers diagnosis, not a
weakened test or immediate cache. If a useful rule exceeds its budget, simplify,
reduce its eligible scope or defer it. Do not invent performance wins or numerical
guarantees in the absence of measurements.

## Deferred candidates: not part of either delivery

The separately authorized [cover art and navigation increment](COVER_ART_AND_NAVIGATION_PLAN.md)
now implements authored outlines, local heading deduplication and explicit
note/auxiliary controls alongside cover art. The table below retains the original
Delivery A/B boundaries; complex columns, caption scheduling, chaptered output
and broad citation/lexical classification remain deferred.

| Candidate | Reconsider only when | Likely owner |
| --- | --- | --- |
| Complex columns/page-role classification | TP5 exposes a reproducible native-order defect and cheaper native options are evaluated | DocumentProcessing |
| Caption/sidebar scheduling | A demonstrated sentence interruption has a reliable source association and clear preview behavior | DocumentProcessing relationships; NarrationCore scheduling |
| EPUB/PDF/text outlines and local heading dedup | A concrete navigation or duplicate-announcement need survives the completed EPUB baseline | DocumentProcessing metadata; NarrationCore only for speech decisions |
| Chapter-split audio/M4B chapters | The user chooses the desired output/workflow semantics | App workflow and existing output libraries |
| Citation/auxiliary narration controls | The user chooses a policy and fixtures distinguish bibliography from explanatory notes | Shared semantic projection; app-owned preference |
| Repeated boilerplate/figure-label suppression | Structural evidence proves the content is nonflow and legal/accessibility concerns are addressed | DocumentProcessing evidence; NarrationCore projection |
| More abbreviations/ranges/dimensions, homographs or OCR spelling repair | A real failure and context-safe bounded correction justify the cost | Existing appropriate extraction/frontend owner |

No generative prose rewriting, global homograph substitutions, keyword-based
chapter reordering, destructive References-tail deletion or automatic removal of
license notices. EPUB outline work must not silently append non-spine resources
or duplicate the parser currently being finished.

## Validation recipes for the implementing agent

**These commands are reference recipes, not results and not instructions to run
while drafting.** Revalidate paths/filters after the EPUB work. Respect the recorded
testing mode. Under manual mode, give the user the applicable command, working
directory, setup, expected executed tests and success criteria; request a pass
report or relevant failure output.

Setup: dependencies must already be prepared at the current pins and resolution
files must match. Native quality checks additionally need explicitly available
local model/G2P assets and the current helper. Ask before network access, downloads,
elevation, expensive profiling or destructive side effects. Neither
`--skip-update` nor locked resolution guarantees offline operation if assets are
missing. Never relax sandboxing/coverage checks merely to get a pass.
Do not search home directories or app data for assets: native checks needing paths
outside the four scoped trees require explicit additional authorization.

### Focused shared fixtures

Working directory: `/path/to/NarrationApps/swift-packages`.

```sh
swift test --disable-automatic-resolution --skip-update --disable-sandbox \
  --no-parallel --jobs 4 --filter 'PreparedSpeechTests|PronunciationTests|SemanticIntakeTests|EPUBIntakeTests|TextEncodingTests'
```

Narrow this filter to affected tests during iteration; add the actual new test names
as they are created. For TP5-TP7 include document preparation/progress and intake
fixtures. Success means the intended tests execute and pass, with opt-in native
skips reported separately. A passing command with zero matching tests is not a gate.
New CPU performance cases may use the same command with `-c release` and a focused
filter after setup; this is not a reason to rerun every native model fixture.

### Required regression gates at a delivery boundary

From `/path/to/NarrationApps/Libro`:

```sh
bash scripts/check.sh
```

This wraps shared and LibroCore fixtures. It invokes dependency preparation, which
can clone, patch and prepare codecs; inspect current readiness/side effects first.
Do not rerun unapproved preparation just because the wrapper is called a check.
In manual mode, hand off this caveat and command to the user.

From `/path/to/NarrationApps/VoiceRelay`, after the shared fixture worker exists:

```sh
NARRATION_FIXTURE_WORKER="$PWD/../swift-packages/.build/debug/NarrationFixtureWorker" \
  swift test --disable-automatic-resolution --skip-update --disable-sandbox --no-parallel --jobs 4
```

During iteration, use the current focused adapter/source-review test filters.
The supplied fixture worker is synthetic pipeline evidence, not real G2P/listening
acceptance. Real native phoneme checks must exercise the new projection with the
current preparation policy, both regions and isolated outputs; do not accidentally
measure a historical comparison policy or call a skipped opt-in test coverage.
If project references change, also run VoiceRelay's documented
`xcodeProjectAppSourcesUseUniqueBuildFileReferences` regression.

### Build-only checks for both consumers

With dependencies already prepared, these use separate generated build directories,
disable automatic package resolution and avoid distribution wrappers. They do not
launch, install, package or sign an app. Unsigned compilation is not distribution
or credential-entitlement acceptance. Do not change stored signing/team settings.

From `/path/to/NarrationApps/Libro`:

```sh
xcodebuild -project macos/Libro/Libro.xcodeproj -scheme Libro \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath macos/.build/TextProcessingPlan/DerivedData \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
```

From `/path/to/NarrationApps/VoiceRelay`:

```sh
xcodebuild -project VoiceRelay.xcodeproj -scheme VoiceRelay \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/TextProcessingPlan/DerivedData \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
```

Do not substitute VoiceRelay's packaging build script blindly: at drafting it can
remove a stale generated app and exchange the `dist/VoiceRelay.app` package. Libro's
build wrapper also invokes dependency preparation. Reinspect build phases before
execution and stop on any new unapproved side effect. Do not copy existing
DerivedData/SwiftPM workspace state into these directories.

### Operator and final-diff acceptance

Use the [consolidated operator checklist](OPERATOR_VALIDATION.md), not a second
competing manual checklist. Extend the relevant entries when behavior is implemented.
Provide short synthetic before/after cases, selected voices/settings and expected
outcomes. The user owns GUI, private-document/OCR quality, listening, protected
files and live-service acceptance. Models/phonemes or synthetic audio do not
prove natural speech quality.

For every completed step, review the final diff and record: implementation scope,
executed commands/results or user-reported results, skipped/unrun checks, output
examples, resource deltas and remaining limitations. Update current shared
documentation/status at the actual behavior boundary; do not rewrite historical
evidence or claim this draft constitutes implementation. Mark checkboxes only
when their evidence is available, including manual-mode results where required.

## Delivery A evidence

Shared ownership remains NarrationCore for mapped spoken forms, Pronunciation for
captured user rules, and ProcessingPipeline for helper supervision. There is no
new product/dependency/CLI, parser, audio effect or model frontend. Soprano stays
unchanged. Existing EPUB/encoding changes and other-agent documents are preserved.

Implementation:

- `ProjectionMapping.swift`: extracted block-local versus spoken UTF-16 runs,
  coalesced unchanged spans, composed whitespace/NFC/known note-marker/user edits,
  explicit generated/unaligned cues, bounded metadata and nil legacy decoding.
- `SpokenFormNormalizer.swift`: job-local native MeasurementFormatter configurations
  for up to seven decimal precisions, explicit US/GB locale and provided units.
  This avoids the SDK's cached-pattern leak when a decimal is followed by integers.
  Native G2P still spells numbers/currency once; negative quantities explicitly
  say “minus.” Valid AM/PM times remove the colon, say “oh” for minutes 01–09,
  and omit zero minutes. Ambiguous/unsupported forms abstain.
- URLs, file paths, identifiers, code, equation neighborhoods and user-rule spans
  stay protected. Bounded matching/indexed context scans replace an initially slow
  wildcard scan. No automatic edit is made without a trustworthy source span;
  arbitrary generated/source alternatives keep existing behavior with a notice.
  Native Markdown/HTML/EPUB carry an optional inline-code flag, protecting the whole
  affected paragraph. Legacy markup without the flag or authored/OCR provenance
  conservatively abstains, preserving retained text without refetch/re-extraction.
- Optional maps survive projection/windowing/host preparation/checkpoints.
  Worker commands strip source/dictionary presentation maps, recomputing a payload
  fingerprint after validating the full host record; the 64 KiB limit stays intact.
  A dense-whitespace regression deliberately exceeds that limit with host maps
  while the actual helper command/render succeeds.
- Semantic version includes `spoken-forms-2-en_US/en_GB` after the letter-A
  follow-up (initial Delivery A was `spoken-forms-1`); raw acoustic identity
  stays unchanged. Exact unchanged text retains compatible completed-chunk
  fingerprints; changed text and native preparation policy revalidate unfinished
  work through existing recovery. Finished/published media is preserved.
- Libro displays planner notices with extraction warnings. VoiceRelay normal/source
  previews capture voice/dictionary once, including after image enrichment, with
  background work and joined cancellation. No new Settings controls are needed.

### Quality, baseline and cost

Red tests first reproduced all seven initial expected forms. Exact-output tests
cover combined quantities with mixed decimal precision, singular/plural, negatives,
Unicode/emoji, known note markers/caption cues, user precedence, unchanged Soprano,
preview/speech parity, window coverage, old artifact decoding, cancellation and
candidate limits. VoiceRelay recovery fixtures protect unchanged completed chunks,
article identity and published audio. Do not treat exact supported phonemes as
listening acceptance.

Synthetic source examples are `2.4 kg → 2.4 kilograms`, `1kg → 1 kilogram`,
`18°C → 18 degrees Celsius`, `−4 °F → minus 4 degrees Fahrenheit`,
`9:30 am → 9 30 a.m.`, `9:05 PM → 9 oh 5 p.m.`, `12:00 pm → 12 p.m.`.
Original extracted text is unchanged. Other unit families, general date/range
normalization, 24-hour times and contextual homographs remain outside this delivery.

Optimized `swiftc -O` CPU measurements used Apple M2 Max, 32 GiB RAM, macOS 27.2,
Swift 6.4/Xcode 27.2 beta. Baseline modules were compiled before the new rules;
PDF extraction code is unchanged. Each text workload ran once cold and three times
warm per isolated process. The table shows median warm projection and process
peak RSS, including process startup/libraries (not incremental allocation or a
native speech-helper footprint). No-change inputs carry no new mapping payload.

| Workload | Baseline warm | Current warm | Current peak RSS |
| --- | ---: | ---: | ---: |
| 10,000 UTF-16 units, ordinary prose | 0.0007 s | 0.0015 s | 7.6 MB |
| 100,000 units, ordinary prose | 0.0074 s | 0.0098 s | 8.8 MB |
| 1,000,000 units, ordinary prose | 0.0732 s | 0.0969 s | 22.0 MB |
| 7,400 units, dense eligible forms | 0.0006 s | 0.0113 s | 12.0 MB |
| 74,000 units, dense eligible forms | 0.0056 s | 0.1016 s | 23.7 MB |
| 370,000 units / 30,000 edits | 0.0272 s | 0.5084 s | 62.5 MB |

The dense baseline does not perform corrections. Current dense output is 589,999
spoken UTF-16 units versus 369,999 baseline units; extra work is expected, not a
claimed speedup. The diagnostic budgets were ≤0.25 s warm for the million-unit
no-change fixture and ≤3 s / ≤100 MB peak RSS for the 370k dense fixture on this
machine. Scaling is consistent with indexed/linear work over these sizes, not a
universal complexity/performance guarantee. Fixed budgets bound 100,000 candidates,
edits, context regions and mappings, plus an 8× + 256 per-stage expansion ceiling.
Cancellation is checked during bounded matching/context/composition intervals.
No extra OCR/G2P runs for CPU projection. Budgets are not brittle CI timing asserts.

Synthetic 2/20/200-page digital PDFs were measured separately with native PDFKit,
three runs each, retaining section anchors. Geometry/OCR algorithms are unchanged;
no OCR ran on those usable-text pages. Raw extraction/projection times, peak RSS,
text benchmark sources, frontend baseline and toolchain identity are retained in
ignored `.build/text-processing/delivery-a/evidence/`. No private book or external
corpus was used. Cold startup and framework/process noise are distinct from warm
work; PDF-specific layout budgets belong to Delivery B.

### Automated checks and operator boundary

Executed gates passed:

- Libro `bash scripts/check.sh`: AppPresentation 2 tests, shared XCTest 193 tests
  with 3 existing explicit opt-in skips, LibroCore 17 tests, native number,
  dependency, shell/project/plist checks. The generated-note-cue cap and dense
  host-metadata regressions executed successfully.
- VoiceRelay full isolated suites: 297 core + 141 app tests. After the final
  mapping-cap change, 43 focused source-review/native-adapter/recovery checks passed.
- Both final ad-hoc arm64 Release builds and complete deep/strict signatures passed.
  No new archive/export, installed-app, GUI or signing-account acceptance is claimed.
- Actual packaged Libro and VoiceRelay helpers each passed 54 offline US/GB frontend
  checks (52 prepared cases plus 2 expected indivisible-word rejections), including
  independently authored full-word references and mixed precision within one job.
- Six actual Heart/Michael/Emma clips rendered offline at 1.0× through shared
  preparation and native AAC output. All six decode completely to finite,
  non-silent mono 24 kHz samples; authored numeric/sign/unit forms were checked.
  Bundled samples, existing audio and user data were not regenerated.
- Documentation local-link/anchor and whitespace checks passed in all repositories.

Baseline measurements, raw costs, fixture sources and named gate logs are under ignored
`.build/text-processing/delivery-a/evidence/`. Native results are in `frontend/` and
`frontend-voicerelay/`; recordings/manifests/decode validation are in `listening/`.
No acceptance checkbox in the operator checklist was marked by these automated runs.

New native cases compare actual US/GB phonemes with independently
authored full-word references under the current pause policy. The harness explicitly
reopens its helper after intentional rejection fixtures; failure-closes-session
behavior is unchanged. Control/reference calls are test-only, not a second runtime
G2P pass. Native frontend timings exclude projection and report preparation/IPC
separately; initialization and expected-rejection restarts are separate costs.

The six synthetic AAC-LC clips use Heart/Michael/Emma at 1.0×, mono 64 kbps/24 kHz,
with original levels and current structural pauses. They are local operator fixtures,
not regenerated bundled samples or finished recordings. Use **B05** in the
[consolidated checklist](OPERATOR_VALIDATION.md); EPUB L15/L16 remain separate.
The operator reports significant listening improvement; all three voices read
the A label as an article. A narrow `spoken-forms-2` correction now changes capital
A to “ay” only after explicit label nouns, preserving source coordinates, user
overrides and ordinary articles. The operator subsequently accepted the corrected listening and authorized
Delivery B below. Unreported GUI checks remain separate; deferred features are
not started.

### Letter-A follow-up validation

The explicit-label correction adds three shared regression tests, covering letter
and article distinction, mapped source spans, preview/speech parity, all three
listening voices, other label contexts, identifier/code protection, user precedence,
unchanged Soprano and compatibility with unchanged version-1 chunks. The full
required Libro/shared gate passes with its existing opt-in skips. VoiceRelay's
43 source-review/native/recovery fixtures pass, including a retained original A
and a corrected HTML preview using the captured dictionary/voice.

Both final ad-hoc arm64 Release builds and deep/strict signature checks pass.
Each packaged helper passes 64 offline US/GB frontend cases (62 prepared cases
and two intended rejections), including exact stressed letter-A phonemes and
unchanged article phonemes. No dependency or model/frontend patch changed.

Three new Heart/Michael/Emma clips at 1.0× use “Package A”, “Plan A” and ordinary
“A car” / “a book” in one paragraph. AAC-LC remains mono 64 kbps/24 kHz with no
audio-level processing; complete decoding yields finite, non-silent samples.
The `.build/text-processing/letter-a/listening/index.html` (archived corrected listening page)
retains source/spoken text, actual prepared plans and decode evidence; the original
listening page links to it without overwriting its audio. Logs and the original
native pronunciation probe are under ignored `.build/text-processing/letter-a/evidence/`.
The user subsequently confirmed the corrected letter-A listening as fixed and
authorized Delivery B. Unreported GUI checks remain operator-owned. Bundled voice samples and finished media are unchanged.

## Delivery B: paragraph and PDF flow evidence

The operator accepted the corrected letter-A listening and authorized the next
implementation stages. TP4–TP7 are implemented with the following explicit limits:

- Plain-text blank lines retain paragraph boundaries before whitespace collapse.
  Concatenating retained blocks reconstructs the decoded text, including CR/LF
  separators. A single newline does not invent a paragraph, list, heading or verse
  interpretation. Authored Markdown/HTML/EPUB structure stays authoritative.
- Mapped discretionary soft hyphens are removed only from spoken word spans,
  including demonstrated PDF page continuations. Original Unicode, hard hyphens,
  numeric references and dictionary precedence remain intact. The common
  `text-flow-1` policy applies to both engines; Kokoro's accepted `spoken-forms-2`
  and raw acoustic/packing/pause policies are unchanged.
- PDFKit supplies native line ranges and page-space bounds; crop coordinates and
  rotation are normalized to visual bottom-left coordinates. Vision paragraph
  bounds survive OCR projection. Only Sendable values persist. Ordinary usable
  digital pages do not invoke additional OCR or models. Original PDF line breaks
  are now retained in source blocks, while ordinary spoken whitespace is unchanged.
- Geometry must reconcile completely with non-whitespace source text. Per-page
  limits are 128,000 UTF-16 units / 1,024 lines, with 100,000 retained lines per
  document. Unsupported/out-of-crop/unreconciled evidence abstains with a bounded
  document warning; page/text/OCR limits remain mandatory.
- Margin omissions require substantial interior body text, separated top/bottom
  geometry, a small line height, a known authored title/author/heading or a
  sequential decimal folio, and repetition on at least three distinct pages in
  a document with at least four evidenced pages. Common labels require 65% page
  coverage; alternating labels require three occurrences and 75% of a parity
  cohort. Folios must share one page-number offset; constant years do not qualify.
  Generic repeated margin prose, unknown running heads, URLs and recognized legal
  notices are retained. This deliberately favors preservation over recall.
- Adjacent upright digital PDF blocks can continue only across consecutive pages
  with matching single-column edges, compatible line heights, full-width edge
  lines, and a lowercase prose continuation after a word/explicit soft hyphen.
  No intervening caption/structure, chapter/quote/list boundary, OCR paragraph-only
  geometry, rotated/ambiguous column or EPUB resource is joined. Groups are capped
  at 16 blocks. Authored hard hyphens are retained: geometry alone cannot decide
  whether `well-` / `known` was an authored compound or a discretionary print wrap.
  Explicit within-page paragraph blocks remain boundaries; there is no speculative
  paragraph/column reconstruction or source reordering.
- Optional `NarrationOmission` records retain page, original block-local UTF-16
  span, rule and reason. Preview notices summarize omissions and continuations;
  compact maps cover changed speech and multiple source blocks. Old artifacts
  decode missing geometry/omissions as nil and are not refetched/re-extracted.
- If optional layout evidence or map budgets are exhausted, text is retained.
  A map-budget case replans once without optional PDF layout before G2P/inference;
  no speech is replayed and mandatory limits still fail explicitly when exceeded.
  A separate measured PDF-layout progress phase accompanies extraction.

### Automated validation and cost

Focused source/mapping/native PDF tests and the required shared/Libro gate passed.
VoiceRelay's full isolated core/app suites passed, followed by affected preview,
native-preparation and recovery adapters after the final margin constraint.
Regression coverage includes CR/LF, blank lines, dialogue/verse/list text, numeric
references, hard/soft hyphens, exact retained source, mapped two-block continuations,
actual PDFKit page-edge/crop/rotation extraction, OCR value projection, alternating
headers, body refrains/headings, legal/URL text, constant years, old artifacts,
incomplete geometry and both evidence/mapping budget exhaustion.

Matched optimized CPU runs used the same M2 Max / 32 GiB, Swift 6.4 / Xcode 27.2
setup and the earlier synthetic sources, without concurrent builds or models.
Warm ranges below exclude the first process/framework initialization iteration.

| Workload | Pre-B warm | Delivery B warm |
| --- | ---: | ---: |
| 1,020,450 UTF-16 units, no-change prose | 0.1743–0.1756 s | 0.1754–0.1766 s |
| 370,000 units / 30,000 spoken-form edits | 0.5058–0.5073 s | 0.5099–0.5121 s |
| 2-page digital PDF extraction | 0.00181–0.00184 s | 0.00252–0.00269 s |
| 20-page digital PDF extraction | 0.01235–0.01243 s | 0.01757–0.01761 s |
| 200-page digital PDF extraction | 0.11966–0.12039 s | 0.17244–0.17740 s |
| 200-page PDF projection | 0.15690–0.15770 s | 0.15961–0.16136 s |

The unchanged/dense CPU fixtures remain below their prior 0.25 s and 3 s / 100 MB
budgets. Dense process peak RSS was about 60 MB in both runs. PDF process peak RSS
was about 63 MB before and 57 MB after; this includes framework/startup noise and
is not evidence of a memory reduction or incremental geometry allocation. The
additional native geometry cost is about 0.055 s per 200-page fixture; spoken text
and ordered section anchors are identical. No extra OCR ran. These are synthetic
workload measurements, not a guarantee for all books or live GUI responsiveness.

Source probes, raw measurements and gate logs are retained under ignored
`.build/text-processing/delivery-b/evidence/`. Final packaged/native evidence and
short matched listening fixtures are recorded there alongside the operator page.
No bundled voice samples, finished audio, private document or live service changed.

## Current operator handoff

Use **B06** in the [consolidated checklist](OPERATOR_VALIDATION.md) for Delivery B
preview, actual-document flow, cancellation/progress and listening acceptance.
Earlier unreported EPUB/encoding/GUI/live-service gates remain separate. No deferred
column engine, caption scheduling, outline, citation or pronunciation feature is
automatically authorized by this delivery.


### Final Delivery B handoff evidence

- Final required gate: AppPresentation's two Swift Testing cases, 217 shared
  XCTest cases (three existing explicit opt-in skips), one additional shared Swift
  Testing case and 17 LibroCore cases pass; dependency, number, shell and plist
  checks pass. The last source fix prevents growing-prefix rescans when blank-line
  matches delimit whitespace-only segments; a 40,000-segment regression preserves
  the decoded source exactly. OCR metadata over the 1,024-line per-page
  budget is discarded as a whole page, preserving every recognized paragraph.
- VoiceRelay's full isolated suites pass: 297 core and 141 app cases. The 43 affected
  source-review/native/recovery cases pass after the final PDF policy constraint.
- Both final ad-hoc arm64 Release builds and deep/strict signatures pass. Existing
  Xcode MLX bundle mutation/App Intents metadata warnings remain nonblocking; no
  signing-account or distribution acceptance is claimed.
- Each packaged helper passes 68 offline US/GB frontend cases: 66 prepared cases
  plus two intended rejections, including independent normal-word references for
  soft-hyphen correction. Both rendered Heart comparison clips decode completely
  to finite, non-silent 24 kHz samples. No level processing is applied.
- The synthetic four-page source retains every body sentence in order, including
  repeated sentences. Exactly eight known title/folio omissions are recorded;
  four source blocks become three spoken groups through one demonstrated page
  continuation. Source/projection/prepared records and an independent UTF-16 source
  accounting result accompany the `.build/text-processing/delivery-b/listening/index.html` (archived B06 fixture page).
- The 200-page digital cost fixture retains 3,200 lines, encoding to 467,969 bytes
  of layout metadata. This is serialized metadata size, not an allocation/RSS claim.
  The final optimized whitespace workload at 24k/120k/240k UTF-16 units took about
  0.0083/0.036/0.072 seconds warm, with 16/17/21 MB whole-process peak RSS. Its
  growth is consistent with the intended linear scan over these sizes.

All raw gates, benchmark sources/results, model-free metadata measurements and
native/audio evidence are local under ignored `.build/text-processing/delivery-b/`.
B06 GUI/actual-document/OCR and listening acceptance remains operator-owned.

Listening pages from completed comparison rounds remain with the original
repository archive. The new checkout retains their accepted decisions and test
corpora; it does not copy generated development reports or build state.
