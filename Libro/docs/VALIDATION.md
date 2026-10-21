# Libro validation

## Native queue controls

The October 20 follow-up adds native glass Start/Pause/Resume, confirmed Skip and
separate Stop controls below the divider beside cover editing, native table drag
reordering, and one concise status bar with Save Location/path/Browse. Queue Actions
retains full diagnostics and anchors popovers for new import/destination/setup/generation
errors; issue messages are also clickable. The
[current status](../../docs/IMPLEMENTATION_STATUS.md#native-queue-controls-and-compact-status)
owns automated evidence and the new review candidate. Operator L02/L05/L12/L13
cover appearance, interactions, safe boundaries and narrower/larger-text windows.
All 35 shared control/scheduling and 32 LibroCore tests pass, along with the full
fixture gate, both workspace configurations and all four complete bundle audits.

The destination path remains selectable and truncates in the middle when space
is limited. The shared current status above records automated evidence and the
latest separate review candidate. GUI acceptance remains operator-owned.
The transport/status-footer candidate is
`../../.build/TransportFooterValidation/Build/Products/Release/Libro.app`;
the full fixture gate, Debug/Release builds and all four bundle audits pass.

## EPUB queue and output choices

The October 20 follow-up accepts unpacked `.epub` folders as one book and requeues
explicitly re-added finished sources. Existing audio is handled at Generate Audio
through Overwrite Existing / Skip Existing / Cancel; skipped rows can be queued
again. All 21 EPUB and five queue/drop tests, the final full fixture gate, both
workspace configurations and all four complete bundle audits pass. The
[shared current status](../../docs/IMPLEMENTATION_STATUS.md#epub-queue-and-existing-outputs)
owns automated evidence and the fresh review build path. L05/L13/L16 remain
operator-owned for Finder drop, dialog interaction and actual-book listening.

The operator confirmed on October 16, 2026 that both relocated apps build and run.
This accepts the basic workspace/build/launch smoke check; detailed document,
listening, setup, persistence and live-service cases below remain separate.

The latest accepted-policy automated evidence is maintained once in the
[shared current status](../../docs/IMPLEMENTATION_STATUS.md) and
[longform implementation record](../../docs/KOKORO_LONGFORM_IMPLEMENTATION.md).
It covers shared/AppPresentation and LibroCore fixtures, actual native offline
workers, Float32 fidelity, complete ad-hoc archives/resources and cross-app arbitration.

From Libro, run `bash scripts/check.sh` for the required isolated regression
gate. Prepare sources with `bash macos/scripts/prepare-dependencies.sh`; build/Archive
with `macos/scripts/build.sh` and `LIBRO_CONFIGURATION=Release` for Release checks.
The test suite does not operate the GUI, private documents or signing accounts.
Coordinated quick/full/native/release commands and evidence are documented in the
root [development gates](../../docs/DEVELOPMENT.md).

The [consolidated checklist](../../docs/OPERATOR_VALIDATION.md#libro)
is the only manual test list: L01–L20 for Libro, B01–B07 for shared behavior and
conditional installation/distribution checks. The earlier A/B profile choice is
complete; final GUI/playback, OCR/caption quality and the original private
12-page PDF/600-word Markdown memory retest remain operator-owned. Synthetic
measurements and compiled fixtures are not those acceptances.

## Automatic document cover candidate

Testing is **autonomous**, confirmed October 17, 2026 in the project instructions.
Automatic-cover checks pass 22 PDF/EPUB and four Libro cover-policy cases;
broader checks pass 61 DocumentProcessing, four PDFContinuation and all 22 LibroCore
cases. The isolated Libro Debug build and bundle/signature/Metal/codec checks pass.
An initial callback-label compile error was fixed with an explicit `progress:` label.
The root full isolated gate also passes with all 237 shared XCTest (three existing
opt-in skips), shared/presentation cases, 22 LibroCore and 303 core/141 app VoiceRelay
cases; see the shared current status for the machine summary.
The currently tested application bundle is not replaced. Focused reruns from
NarrationApps after pinned source setup:

```sh
swift test --package-path swift-packages --disable-sandbox --skip-update \
  --force-resolved-versions --no-parallel --jobs 4 \
  --filter 'PDFCoverTests|EPUBIntakeTests'
swift test --package-path Libro/macos/LibroCore \
  --scratch-path Libro/macos/.build/CoreTests --skip-update \
  --force-resolved-versions --no-parallel --jobs 4 --filter DocumentCoverTests
```

Both commands should pass without speech models or live services. The ad-hoc
engineering build is at `.build/AutomaticCoverValidation/Build/Products/Debug/Libro.app`
relative to NarrationApps, separate from existing workspace products. Use a normal
Xcode-signed candidate when account behavior matters. Verify automatic artwork,
manual overrides/removal and cancellation
through L17 in the consolidated checklist. Covers stay uncropped, original source
bytes/audio stay unchanged, and a missing optional cover must not stop other imports.

## Progressive PDF preview candidate

The shared [current status](../../docs/IMPLEMENTATION_STATUS.md#libro-progressive-pdf-previews)
records the live narration/source preview follow-up and its automated evidence.
PDF previews begin at the rounded-up first 5%, capped at five pages, then grow in
the background. Partial results are labeled; closing cancels the remaining work.
Review layout, resizing, scrolling, completion and close/reopen behavior through
operator L20. Existing cover-row changes remain in this candidate; prior app
bundles and completed recordings are preserved.

## Existing feature gates

For package-resolution and diagnostic steps use [troubleshooting](TROUBLESHOOTING.md).
Older paths/counts and retired worker modes are [historical evidence](README.md#current-and-historical-records),
not current release candidates. Documentation-only checks do not constitute a new
app build or operator signoff. Current EPUB/encoding fixture, build and offline
render evidence is in the shared status; L15/L16 cover its remaining operator checks.

Delivery A mapped-spoken-form and preview validation is ready for operator B05;
[the shared plan](../../docs/TEXT_PROCESSING_IMPROVEMENT_PLAN.md#delivery-a-evidence)
records current gates, costs and listening artifacts. Delivery B remains gated.

The cover/navigation increment adds L17–L19: per-document export art, authored
Contents/source navigation and explicit note/auxiliary controls. Canonical authored
fixtures/expectations remain in the shared tests; earlier generated
`.build/cover-navigation/fixtures` outputs are historical and may be absent.
Packet/Float32 preservation, source-map and isolated workflow tests are engineering
evidence; real-player cover display/seeking, GUI and actual-book listening remain
operator checks.

When checking L17, confirm the empty-selection hint points to cover art and WAV
explains which formats support it. The existing-output confirmation should list
the conflicting output filenames; Cancel must leave those files untouched.

The October 18 Settings follow-up adds Document between General and Models. L02/L19
now covers its plain-language text controls, hover help, changing illustrative
examples and image descriptions. Examples start collapsed behind Show example,
with a trailing rotating chevron; Pronunciation remains only in its own pane.
L04 also covers the centered 75%-width pronunciation list and editing buttons,
which resize with the window. Saved choices/defaults and batch capture semantics
are unchanged; VoiceRelay shares the new control labels and dictionary layout.

The citation/column follow-up renames Footnotes and adds two off-by-default citation
choices. L19 covers independent inline/endnote filtering and explanatory-note
preservation; B06/B07 covers always-on recurring margins, supported columns and
dictionary-constrained word repairs. Three operator-authorized book comparisons
stay private under the parent's `.local/document-cleanup/`; see the shared status
for final automated evidence. GUI/listening acceptance remains separate.
