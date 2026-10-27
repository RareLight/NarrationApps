# Current implementation status

Current-state documentation reviewed October 21, 2026. Product evidence remains
the October 20 validation described below. NarrationApps is one repository containing Libro,
VoiceRelay, SwiftNarration, AppPresentation and the combined Xcode workspace.
The containing commit identifies all maintained source. See
[monorepo migration](MONOREPO_MIGRATION.md), [architecture](ARCHITECTURE.md),
[remaining work](IMPLEMENTATION_PLAN.md) and [operator validation](OPERATOR_VALIDATION.md).
Private document reviews and their input-specific results are retained locally;
they are excluded from the publication history. Synthetic fixtures remain maintained.

## VoiceRelay timed episode transcripts

October 25 implementation adds General → Episode transcripts → Publish timed
transcripts, default-on and captured for newly queued articles. Historical jobs
without a captured choice and finished recordings stay unchanged. The shared
native AAC encoder reports measured input intervals after resampling and actual
gap insertion. VoiceRelay uses final prepared text to produce bounded WebVTT cues
at synthesis-segment granularity, without ASR, word-time estimates or audio gain.

Transcript text, audio/content hashes and independent retry state persist with
episode metadata through encoding resume, cache cleanup and library backup.
Authenticated sidecar readback precedes a standard `podcast:transcript` RSS link.
Failures leave audio/other entries publishable; Uploads retains transcript retry
and pending-feed states. Namespace-aware recovery preserves supplied references;
retirement removes only owned current-destination sidecars after feed removal.

Eight focused transcript fixtures and the persisted-preference app test pass,
covering default/legacy/off settings, cue escaping and measured intervals,
encoding resume, backup, upload readback, cancellation, retry, host changes,
server recovery, feed failure and removal ordering. Ten synthetic shared audio
fixtures pass; the explicit captured-native-audio test remains an opt-in skip.
The full project fixture gate also passes, including 319 VoiceRelay core tests,
161 app tests, shared/Libro suites and synthetic packaging regressions. Retained
evidence is `.local/validation/full-7BFF03FC-089E-4159-A5A6-3071743A21F3/`.
Debug and Release workspace builds and all four bundle/signature/resource/Metal
audits pass. These ad-hoc engineering candidates are in the separate
`.build/TranscriptValidation-20261025/Build/Products/{Debug,Release}/` directory;
no operator app was installed or launched. Local logs use the
`.local/transcript-workspace-` and `.local/transcript-<app>-` prefixes.
Live host MIME/access control, GUI, listening and installed Overcast TestFlight behavior remain
operator acceptance [V22](OPERATOR_VALIDATION.md#voicerelay).

## Standalone TTS model comparison

October 24–25 implementation adds the [Swift benchmark utility](../tools/TTSBenchmark/README.md),
independent of either app. It explicitly prepares pinned model assets, supervises
serial offline workers with time/memory bounds, preserves native-rate audio and
records timings, output hashes and durable attempts. A resumable blind model/voice
bracket precedes separate held-out and long-form finalist confirmation.
Cold/warm loads and product-reference variants are timing evidence, not additional
listening entrants. App model catalogs, settings and audio processing are unchanged.

All 19 isolated benchmark tests passed. The full project fixture gate, Debug and
Release workspace builds and four bundle audits also passed in a separate
validation directory; no operator app was installed or launched. Command-local
selection of the installed Metal toolchain resolved compiler discovery without
changing project pins or deployment targets.

The M2 Max/32 GiB comparison produced 224 recordings from 12 direct narrator
profiles plus two accepted-product references. An initial zero-audio Kokoro Emma
region mismatch was fixed, tested and rerun separately; the derived report keeps
the original failure, source receipts and both builds' evidence. All WAV hashes,
12 unique bracket entrants, empty preference history and page audio links were
verified. Fish S2 Pro remains blocked for a licensed reference clip/transcript.
The [design/evidence record](TTS_MODEL_BENCHMARK_PLAN.md) identifies local reports
and measurement limits. Operator [M01](OPERATOR_VALIDATION.md#model-evaluation-developer-utility)
remains open: no listening winner, finalist long-form acceptance or product model
integration is claimed.

The October 25 follow-up replaces per-choice CLI entry with a server-free local
HTML/JavaScript scoring app. Anonymous labels and hashed audio paths conceal names;
the separate identity file is selected only for an explicit final reveal. Browser
storage, JSON backup/restore, notes and revisions preserve choices. A validated
one-time export import connects them to the existing Swift finalist workflow.
The JavaScript tournament is checked against the Swift engine; local-file browser
inspection is blocked by the automation tool, so visual/audio/file-permission
acceptance stays with the operator.
The standalone Release build and all 26 model-free benchmark tests pass, including browser-state save/reload,
stale-tab protection, backup fallbacks, anonymous exports, revision replay and
cross-language tournament fixtures for odd/even fields, rejected pairs and final
resets. Scoring fixtures use JavaScriptCore. A synthetic, in-memory Apple WebKit
fixture additionally verifies initialization, aligned audio/buttons/notes, minimum
control heights and no horizontal overflow at 360, 744 and 1024 pixels. It does not
establish actual Safari playback or local-file permission acceptance.

The Safari layout follow-up gives player cards and the notes/decision panel shared
spacing and responsive grids. The source template is now `bracket-template.html`
to distinguish it from the generated listening page. A startup notice identifies
an uninitialized page and scoring controls stay hidden until initialization.
Opening the template directly cannot load styling, scoring or audio sources;
the generated run-folder page is required. Regeneration verified unchanged
canonical choices, run identity, aliases and progress storage key, plus all 24
anonymous audio hashes. The project quick gate and documentation checks also pass.

## VoiceRelay menu-bar clicks

The menu-bar item now hosts the existing SwiftUI menu in a native status-item
popover with animations disabled for immediate presentation. Left- and right-click
share one button action; Escape/outside-click use
native transient-popover dismissal. Window/Settings actions retain their SwiftUI
scene actions and close the popover first. Input and focus acceptance remains
part of operator case V02.
The menu fits command labels at the selected text size; status/progress wrap
within that width, and keyboard focus effects stay hidden until Tab is pressed.
The October 23 follow-up adds 25% horizontal room, a larger SF Symbol
and Copy Podcast URL. The final symbol correction restores the standard square
slot and doubles the symbol's configured point size instead of its image canvas.
Shared citation controls now sit
beside the other narration options without a nested group box. The authored
default cover, runtime lookup, Xcode resource and bundle audit now use JPEG.
The original menu host passed all VoiceRelay core/app fixtures and Release app
compilation. October 23 polish validation passed 56 selected core tests, 23 selected
app tests and the shared narration Settings composition test. Menu checks include
80%/100%/200% sizing, 25% extra width, changing status, both kinds of progress and
copying the configured feed URL to an isolated clipboard. Debug and Release
workspace builds and all four bundle audits passed, including exact JPEG resource
bytes. The shared test initially encountered a stale Metal compiler mount in build
metadata; regenerating that metadata resolved it without source or pin changes.

Ad-hoc validation candidates for the `e0455a6` working tree with these uncommitted
changes are under `.build/MenuArtworkValidation-20261023/Build/Products/{Debug,Release}/`.
Neither app was installed or launched. These candidates predate the final symbol
configuration correction; rebuild current source for V02. The older title-recovery products below
predate the menu changes; V02 and V12 remain operator acceptance.
A local converter comparison produced a 223,515-byte JPEG from the previous PNG
and a 199,660-byte JPEG from the replacement, both 1700×1700. Original PNG size
alone does not explain missing player artwork; public access and Overcast display
remain unverified. Existing saved cover choices are preserved.

## VoiceRelay article title recovery

October 23 implementation: new asynchronous intake checks title quality and treats
embedded titles matching either PDF filename as weak. Useful Reading List titles
and reliable opening headlines take precedence over those fallbacks. Optional
on-device title generation is off by default and uses bounded opening text through
the shared inference lease. The chosen title/provenance persists with approved
text; All Articles retains a local display title without modifying Safari. Queued
previews use saved source text, and unattempted queued articles support Edit Title.
Started work, existing snapshots and published recordings are not automatically
retitled. See [source handling](../VoiceRelay/docs/SOURCE_REVIEW.md#title-recovery).
Automated evidence includes a passed full fixture gate, final focused title/source/PDF
regressions, Debug and Release builds of both apps, and all four bundle audits.
The engineering products are under `.build/TitleRecoveryValidation-20261023`;
they do not replace the operator's selected app. Real-document title quality,
Settings and contextual editing remain [operator checks](OPERATOR_VALIDATION.md#voicerelay).

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
