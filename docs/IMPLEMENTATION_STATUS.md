# Current implementation status

Current-state documentation reviewed October 21, 2026. Product evidence remains
the October 20 validation described below. NarrationApps is one repository containing Libro,
VoiceRelay, SwiftNarration, AppPresentation and the combined Xcode workspace.
The containing commit identifies all maintained source. See
[monorepo migration](MONOREPO_MIGRATION.md), [architecture](ARCHITECTURE.md),
[remaining work](IMPLEMENTATION_PLAN.md) and [operator validation](OPERATOR_VALIDATION.md).
Private document reviews and their input-specific results are retained locally;
they are excluded from the publication history. Synthetic fixtures remain maintained.

## Monorepo migration

The app source histories are imported under `Libro/` and `VoiceRelay/`. No
submodules or nested app repositories are required. Source paths, package identities,
build graphs and runtime settings retain their existing layout. Setup prepares
pinned dependencies; it no longer clones applications. Health and validation
record one root revision, with strict health requiring a clean working tree.

Original Git metadata and import maps are retained in ignored local migration
storage. Historical private validation records, document excerpts, local signing
configuration, obsolete generated icon output and personal home paths are excluded
from the imported history. Product artwork, license notices and the maintained
synthetic voice samples remain included. The requested GitHub origin is configured;
the initial source publication was subsequently performed manually. Source
publication does not imply CI activation or binary distribution.

## Native queue controls and compact status

Libro uses native circular SwiftUI controls for Start/Pause/Resume, Skip and Stop,
with corresponding menu commands. Stop and Skip require confirmation. Pause keeps
partial audio and releases inference admission at a safe boundary. Queue dragging
preserves selected-row order and the current/next-batch partition. Destination,
readiness and queue status share the bottom bar; issue messages open diagnostics.
Existing completed audio and late-arriving queue items retain publication protection.

## EPUB queue and existing outputs

Bounded normalization accepts unpacked EPUB folders through selection, drop and
recursive scans without repacking source files. Linked/unsafe resources and
malformed packages fail explicitly. Finished sources can be queued again; existing
outputs are reviewed through Overwrite Existing, Skip Existing and Cancel before
speech begins. Replacement permission is scoped to the captured batch.

## Prose insets and equation flow

The shared `scientific-text-2` projection preserves paragraph order in prose-heavy
tables and places supported OCR insets relative to the page body. Complex equations
receive one original-text reference per document after column reconstruction.
Every region retains its source range and page. Recognized compatible extraction
and acoustic-policy aliases preserve identical completed requests.

## Scientific equations and tables

Simple verified linear notation uses bounded speech rules. Fragmented or uncertain
formulas receive source-reference cues, retaining original text and mappings.
Advanced mathematical speech remains deferred. Explicit table cells receive labels;
ragged grids and uncertain OCR get conservative cues. Optional bounded native OCR
can recover image-table text while preserving the native page. Native extraction,
MathML handling and complex layout still have limits. See
[scientific narration](SCIENTIFIC_NARRATION.md) and
[academic PDF findings](ACADEMIC_PDF_EVALUATION.md).

## Citation choices and PDF narration reconstruction

Academic citation controls follow Footnotes. Inline and endnote stripping default
off and preserve existing saved preferences. Confirmed reference structures can
support omission; uncertain prose, dates, arrays and explanatory notes remain.
PDF margin cleanup requires repeated isolated geometry; supported column bands
reconstruct only the spoken projection. Original text and UTF-16 mappings remain.
See [narration cleanup](DOCUMENT_CLEANUP.md).

## Shared pronunciation Settings presentation

Both apps use shared PronunciationUI and AppPresentation components. The editor
uses the requested width and a rounded settings-section background. Scope guidance
appears under an information control. Preview dependencies are supplied by the apps;
editing behavior and existing dictionary persistence remain shared.

## VoiceRelay bundled default podcast cover

VoiceRelay bundles its authored cover image as the initial podcast artwork.
Existing custom artwork and explicit user changes retain precedence. Packaging
checks compare the bundled resource to the maintained source image.

## VoiceRelay background credentials and optional login startup

Background credential access avoids interactive Keychain prompts; explicit settings
actions handle credential changes. Rebuilding or changing signing identities can
change Keychain authorization independently of application logic. Optional login
startup uses the platform service API, defaults off and is available in initial
configuration and Settings. Keychain behavior, system approval and reboot/login
acceptance remain operator-owned.

## Libro Document settings

Document examples are collapsed by default behind disclosure controls. Shared
Settings sections own common narration and pronunciation presentation; app-specific
preferences and workflows stay with each app.

## Libro progressive PDF previews

Initial PDF analysis processes the first five percent rounded up to complete pages,
capped at five pages and at least one.
Narration/source previews can populate before full analysis finishes; background
progress and cancellation retain document/session identity. The interface labels
this work as text analysis. Preview sizing and controls avoid compressed text layout.
Actual-document responsiveness and visual acceptance remain operator-owned.

## Automatic Libro document covers — automated checks complete

Assigned or detected cover artwork is visible beside library titles. Native cover
discovery preserves explicit choices and intentional removal. EPUB/PDF cover paths
use existing bounded intake and artwork handling rather than replacing source files.

## Experimental PDF printed-word joining

Printed-word joining is opt-in and defaults off. It uses local line geometry,
structural exclusions and platform dictionary evidence; ambiguous cases abstain.
Discretionary soft-hyphen cleanup remains separate. Original source text and mappings
are preserved. The Readium adaptation's BSD notice and provenance are retained.
See [text processing](TEXT_PROCESSING_IMPROVEMENT_PLAN.md) and
[provenance](PROVENANCE.md).

## Accepted policies and engineering gates

The existing operator-accepted Kokoro baseline remains Heart at 1.0× with actual
phoneme packing and structural pauses. Saved speeds, captured jobs and Soprano's
frontend remain compatible. Audio is never normalized, levelled, limited or given
gain. MLX stays helper-only, with one worker per app and shared admission priority.

The latest recorded cross-app product validation is the October 20 monorepo gate:
full synthetic fixtures, Debug and Release workspace builds and all four bundle
audits passed. Those audits include
ad-hoc signatures and offline packaged Metal probes. Migration-specific results
are recorded in [the migration record](MONOREPO_MIGRATION.md).
Build/fixture evidence does not establish GUI, listening, private-document,
Keychain, live-server or distribution acceptance. The consolidated
[operator checklist](OPERATOR_VALIDATION.md) retains those gates.

## Documentation review — October 21

Root and app entry points now distinguish users, power users, developers and agents.
The [narration guide](NARRATION_GUIDE.md), [documentation index](README.md) and
[documentation policy](DOCUMENTATION.md) explain current controls, guide ownership,
command scopes and historical records. UI labels/defaults and setup were checked
against the current source. No application behavior, dependency pin, audio policy,
manual acceptance or release state changes as part of this review.

Documentation validation passed the quick tier (static checks and 78 isolated
development-tool assertions), recorded in
`.local/validation/quick-E2354F2A-29D0-4FB6-B48D-789DBF3652EA/summary.json`.
Nested package/build/icon/provenance guide links were checked separately. These
results validate documentation/tooling, not a new application or live-service run.
