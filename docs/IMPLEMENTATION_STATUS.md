# Current implementation status

Current-state documentation updated October 30, 2026. Feature-specific engineering
evidence is dated below. NarrationApps is one repository containing Libro,
VoiceRelay, SwiftNarration, AppPresentation and the combined Xcode workspace.
The containing commit identifies all maintained source. See
[monorepo migration](MONOREPO_MIGRATION.md), [architecture](ARCHITECTURE.md),
[remaining work](IMPLEMENTATION_PLAN.md) and [operator validation](OPERATOR_VALIDATION.md).
Private document reviews and their input-specific results are retained locally;
they are excluded from the publication history. Synthetic fixtures remain maintained.

## Mandatory semantic phrasing and shared setup banner — current

Semantic phrasing is now the only production preparation path for all five
product models, superseding the Kokoro-only activation below. Saved
`SpeechSettings.planning` values decode as inert compatibility metadata and no
longer change effective preparation: Kokoro selects its current policy, every
other model selects native text, and every non-Kokoro narration version carries
`semantic-boundaries-1`. Incompatible unfinished plans reprepare under the
current identity; completed recordings and prior comparison pages are
preserved. New baseline-versus-semantic comparisons are retired.

Missing selected models now present one shared **Speech Setup Required**
header: above Libro's main voice controls, at the top of VoiceRelay's Voice
Model settings, and in VoiceRelay's workspace readiness area. It owns the
Download/Cancel action, scope-aware byte progress, separate checking and
validation states, retryable failures and reduce-motion-aware collapse; the
former inline download arrow and phrasing toggle are removed. Model details
stay beside the visible model menu and format pickers size to their content.

Final full fixtures pass in `.local/validation/full-C42389FC-203E-446B-90E5-E04912A61DD7/`.
Final Debug/Release workspace builds and all four bundle audits pass in
`.local/validation/release-D426E790-AA69-4F2B-A720-1894B0508C7B/`; archives were
skipped. The standalone benchmark's 27 fixtures passed; its output was not saved
to a validation directory. GUI and listening acceptance were not performed; no
models were downloaded, no live services used and no apps installed or replaced.

## Mandatory Kokoro semantic phrasing — October 30

Following the operator's paired listening and explicit activation decision, new
Kokoro narration always uses semantic phrasing in both apps. Its experiment switch
is removed; older saved preferences cannot disable the policy. Other models retain
their opt-in switch and existing defaults. Switching away from Kokoro does not
implicitly enable the experiment for another model.

`phoneme-semantic-compounds-2` also protects letter-to-letter compounds from internal
packing splits and converts their aligned hyphen pause phones to word separators.
Source hyphens/mappings, real dashes, numeric handling, audio levels and the hard
510-phone ceiling are preserved. Incompatible unfinished plans are reprepared;
old completed recordings and bundled samples remain historical. Explicit review
repair/continuation prepares only generated passages with current packing and
reuses unchanged verified PCM. New phrasing comparisons exclude Kokoro; existing
blind pages and choices remain readable. Compound naturalness and current UI
remain operator checks in B09.

Full fixtures pass in `.local/validation/full-B94B7AEB-961C-4DBB-9A0A-E994A54CB55C/`.
Final Debug/Release workspace builds and all four bundle audits pass in
`.local/validation/release-2E09E733-7746-475C-ADE8-4C948514F33C/`; archives were skipped.
The full rerun includes the corrected source-only checkpoint compatibility cases.
All 27 benchmark fixtures pass; an inert-helper routing check verifies exactly
four non-Kokoro models, eight retained expected failures and no invalid audio.
Each packaged helper passed 36 frontend cases in both US and GB English, including
ASCII/Unicode compounds. Two native compound WAVs passed independent finite-PCM,
frame/hash, source-coverage and no-dash-phone checks. Private receipts and short
listening samples are under `.local/kokoro-semantic/`. No models were downloaded,
installed apps replaced or live services used.

## Long-form narration quality — October 30

Operator paired listening is now recorded in the
[listening results](LONGFORM_QUALITY_LISTENING_RESULTS.md): semantic phrasing was
preferred for Kokoro/Heart; all four other pairs were rated Same. Contextual
read/lead, selected unit/time pronunciations, paragraph timing and Ryan's pacing
remain follow-up issues. This supports considering Kokoro-only activation on
this evidence; the initial import did not change defaults. The subsequent operator
decision above activates it for Kokoro. B09 remains partial because GUI,
recognition and broader pronunciation acceptance were not reported.

The authorized [implementation plan](LONGFORM_QUALITY_IMPLEMENTATION_PLAN.md) is
implemented across the shared packages and both apps. Semantic phrasing is now
mandatory for every model, including saved legacy/nil planning values, previews,
resume/review repair and direct native sessions; the former opt-in control and
inline download action are retired in favour of the shared setup banner.
Native-text English spoken-form expansions and private review retention remain
opt-in. Scoped language/document/model rules, trusted aligned
Kokoro phones, sentence-context previews, name-review drafts and optional Qwen
delivery presets share one implementation. See [behavior and limits](LONGFORM_QUALITY.md).

Private immutable plans and bounded chunk journals support read-only duration,
silence/repetition checks, installed-only local Apple recognition, explicit
selective/current-rule regeneration, continuation of missing passages and a new
WAV export with measured frame intervals. Repairs stream one passage at a time.
Corrupt frame/hash metadata fails before byte accounting. Source records,
finished audio, publishing and authoritative transcript timing remain independent.

The new Swift product-pipeline comparison rendered five matched pairs (ten native
Float32 WAVs), with no failed takes in the final run. Native US/GB checks also
validated scoped phone overrides, preserved written text and rendered audio.
The first native run exposed Qwen's hidden input-length-derived output cap; an
opt-in adapter now honors the already-declared 4,096-token ceiling. The same
fixed-seed passage completed with accepted and candidate preparation afterward.
Its generation identity changed; memory, timeout, duration and clean-EOS guards
remain active. Old recordings and failed-run evidence are preserved.

Final full fixtures pass in
`.local/validation/full-7956855B-3686-4B6D-82EF-999B525C2660/`; final Debug/Release
builds and all four bundle audits pass in
`.local/validation/release-4BE588B8-38A7-4043-92C3-C15C1EBC6BF2/`.
The benchmark's 27 isolated fixtures pass. An inert failing-helper run verifies
four preserved failure receipts, continuation and no invalid listening clips.
Native audio hashes, finite samples, frame counts, matched settings and anonymous
page data pass independent inspection. Private receipts/source fingerprints are
under `.local/longform-quality/`. Paired audio was rendered before the last
cache-integrity/editor/streaming-repair refinements; generation source is unchanged,
and final packaged frontend checks remain separate receipts.

The listening page is
`.local/tts-model-benchmark/phrasing-20261030-final/comparison.html`.
Open it directly; identities remain outside page data until an explicit final
reveal. Current ad-hoc app candidates remain under
`.build/WorkspaceDerivedData/Build/Products/Release/`. No installed app was replaced,
no models downloaded and no live-source/server operation performed. Archives were
skipped. GUI, local recognition availability and listening are operator-owned B09;
automated recording checks alone do not establish that the candidate sounds better.

## Libro voice-control layout and Qwen help — October 29

Libro's main-window voice controls now use a tightly fitted wrapper, with 6pt
vertical and 4pt horizontal spacing scaled to text size. Model/Voice stay anchored
to the top/leading edge; simpler models shrink the header, while narrow layouts
place Output format below the voice controls and scroll either group when needed.
The inline Format label keeps its dropdown level with Model. Qwen's separate
Native row is removed in both apps; the native language is bold and star-marked
inside the Language menu, with regional detail in hover/accessibility help.
Settings remains focused on model storage/setup. Both apps share the Qwen Delivery
label/field tooltip explaining tone/pacing cues, default delivery when blank and
the 128-character limit. Their shared controls/scrollers retain intrinsic height.

All 14 NarrationUI tests passed, including offscreen sizing across models,
control states, narrow widths and text sizes, plus native-language emphasis for
all Qwen voices and regional Chinese variants. The quick gate, Debug/Release
workspace builds and all four bundle audits passed; archives were skipped.
Current build receipt:
`.local/validation/release-E68D2341-3E0A-442F-AF54-924FD749B21B/`.
Focused logs/source hashes are in `.local/voice-menu-labels/`. No installed app
was replaced; visual/hover acceptance remains operator-owned.

## Duplicate article management — October 29

VoiceRelay now selects one readable copy of duplicate Reading List articles,
using original URL or normalized title plus original website. Fuller extracted
prose wins; within 5% of the longest copy the newest save wins. Inactive copies
remain gray and labelled in All Articles. Extraction evidence and handled save
IDs commit with admission, preserving suppression across source refresh, restart,
queue reset and audio removal. A genuinely new save or explicit active-copy
requeue can create fresh audio with current settings.

Intentional replacements preserve old history while the new audio and feed
membership are confirmed. A bounded second feed publication removes older
matching episodes before owned audio/transcript deletion. Failed delivery and
interrupted cleanup remain recoverable. Legacy source/date backfill and Safari
entry retargeting preserve their identity boundaries; managed speech resumes its
captured episode ID rather than a mutable URL slot. See the [user guide](../VoiceRelay/docs/USER_GUIDE.md#duplicate-articles)
and [admission contract](../VoiceRelay/docs/ARCHITECTURE.md#duplicate-admission-and-replacement).

The complete VoiceRelay suites passed 346 core and 175 app tests. Final focused
checks passed 20 tests, including missing superseded temporary audio, legacy
metadata/date recovery, unchanged-save suppression and replacement failures for
both matching and differing source URLs. The quick gate and documentation/link
checks passed. Final Debug/Release workspace builds and all four bundle audits
passed in `.local/validation/release-4106C2E3-8477-440C-999A-19F942E783D4/`.
Archives were unrequested. Synthetic logs and source hashes are retained under
`.local/article-duplicates/`. Ad-hoc candidates remain under
`.build/WorkspaceDerivedData/Build/Products/{Debug,Release}/`; no installed app,
Safari source or real server content was changed. Real Safari, GUI, listening and
live-server acceptance remain operator-owned under V06.

## Immediate Server Audio removal — October 29

VoiceRelay now hides accepted Server Audio removals immediately, without row
animation or a visible in-process row. A serial owned local-removal queue accepts
further clicks while preserving unrelated rows/selection. The lower status bar
shows pending cleanup. Canonical episode records and feed-before-delete safety
remain unchanged; this is optimistic presentation, not server confirmation.

Library refreshes and delivery snapshots cannot resurrect active hidden rows.
Local failures and completed server attempts with unfinished work restore the
affected items; newer requests remain hidden until their own follow-up attempt.
Publishing-off/unavailable work is restored as pending, and quit joins/cancels the
owned queue without running later requests. Upload-copy deletion remains exclusive.

All 174 VoiceRelay app tests pass, including delayed server DELETE, rapid local
clicks, polling, duplicate/stale actions, ownership-validation failure, feed-update
failure, Publishing disabled, follow-up drains, preserved selection and quit.
Synthetic gates also verify that stalled cleanup leaves the MainActor responsive.
Quick static/tooling/docs pass in
`.local/validation/quick-7972FDC2-1F87-46DF-96F7-47E5E808C6D0/`.
Debug/Release workspace builds and four bundle audits pass in
`.local/validation/release-9A2CFFEA-11E5-4832-AA70-702006871A80/`.
Private logs are `.local/optimistic-server-audio-removal/`. Archives were skipped;
no real server, Keychain credentials or installed app was used/replaced. Actual
list smoothness and live-server acceptance remain operator-owned through V14.

## Compact voice controls and inventory columns — October 29

Both apps now keep file sizes and deletion exclusively in Downloaded models.
The shared voice picker has a narrower label/metadata area and only download
when missing plus adjacent model details; cached-model repair remains in the
details popover. The common control width drops from 376pt to 296pt, scaling with
text size, while preserving common menu positions and dynamic section height.

Downloaded-model rows use fixed name, right-aligned size and trash columns
(120/80/32pt with 8pt gaps, scaled to text size) directly below folder controls.
They no longer stretch to the window edge. Narrow windows scroll the table;
imported folders have no delete action. Folder changes invalidate pending targets,
the confirmed root/model is rechecked before deletion, and app activation refreshes
the inventory. Shared storage leases and preservation of recordings remain intact.
This supersedes earlier picker-row size/trash presentation below.

Seventeen focused tests pass: thirteen shared presentation/storage regressions
and four VoiceRelay Settings/health regressions. Inert sizing checks cover long
model names, small/large file sizes, imported rows, text enlargement and horizontal
scrollers, without invoking actions or reading real model/profile storage.
The initial 56pt label column failed the Language-label fit check; the final
60pt column passes. Quick static/tooling/docs pass in
`.local/validation/quick-C2C31E63-ED74-49E1-931B-FF0C5A6B70D8/`.
Debug/Release workspace builds and four bundle audits pass in
`.local/validation/release-EA161412-07CD-44B0-B53C-2EA525F2D3DC/`.
Private logs are `.local/model-inventory-columns/`. Archives were skipped;
actual GUI/deletion-flow acceptance remains operator-owned.

## Unified concise model setup and startup defaults — October 29

Both apps now display the same Model Setup window from NarrationUI, with one
short local-speech explanation, shared status/progress, custom-folder selection,
Install Model/Check Model, Not Now and Cancel. There are no app-specific content
slots, paths or startup controls. The common component dismisses on verified
readiness; apps retain the owned download/check/cancel operations. Libro also
joins readiness checks on cancellation and keeps preflight failures visible.

VoiceRelay requests main-app login startup once for fresh configurations. General
Settings is the only place for the toggle. Existing preferences/library state,
explicit opt-outs, OS approval/revocation and failed enrollment are preserved;
there is no automatic retry on later launches. Tests use fake login services,
not real registration. Libro's idle status cell is blank while progress and
diagnostics remain visible during work.

Twenty-four focused tests pass: twelve shared presentation/storage regressions
(including compact setup sizing and expanded errors) and twelve VoiceRelay
onboarding/login/Settings regressions. Quick static/tooling/docs pass in
`.local/validation/quick-06FCFA46-E991-4024-BA2D-13D1AD86BF7F/`.
Debug/Release workspace builds and four bundle audits pass in
`.local/validation/release-A9042BE2-EAAB-4A53-A799-4199827C142F/`.
Private evidence is `.local/shared-model-setup/`. Archives were skipped; actual
signed-app login/reboot behavior and full GUI acceptance remain operator-owned.

## Tighter control spacing — October 29

Both apps now use 6pt row gaps and 4pt column gaps in the shared model chooser,
scaled to text size. The column gaps are halved from 8pt, including the gaps
between storage action, size and info. The section's width is reduced accordingly;
Libro also halves the gap to its output-format column from 16pt to 8pt.
The section still fits only the active model's controls and keeps common menu
alignment. This supersedes the 8pt row spacing in the earlier revision below.

All eleven shared tests pass, including 60 inert offscreen model/text/playback
layouts. Static/tooling/docs pass in
`.local/validation/quick-2766DB3D-08D5-40C2-BBE4-046F5B029A8D/`.
Debug/Release workspace builds and four bundle audits pass in
`.local/validation/release-7306D90B-D4ED-4013-ACAD-A94F57127A69/`.
Private logs are in `.local/model-controls-spacing/`. Archives were skipped;
GUI acceptance remains operator-owned.

## Compact section height — October 29

The shared model chooser now sizes vertically to only the selected model's
controls in both apps. It no longer measures/reserves invisible options from
other models. Model and Voice retain their top/left columns; options and Sample
initially followed with 8pt row gaps (previously 16pt); the later spacing revision
above tightens these further. Simpler models
leave more room for the surrounding content. This supersedes the fixed panel
height in the earlier row/layout revisions below.

Eleven shared tests pass, including 60 inert offscreen layouts checking variable
height, common width, playback/busy-state stability and enlarged text. No real
model/profile reads, actions or app windows are needed for these component checks.
Static/tooling/docs pass in
`.local/validation/quick-9A26FA75-64C9-4600-A556-6D231442E293/`.
Debug/Release workspace builds and four bundle audits pass in
`.local/validation/release-BC631ECB-56DA-4F5E-B2A8-84DBE5927C3C/`.
Private logs are under `.local/model-controls-fit/`. Archives were skipped;
full-app GUI acceptance remains operator-owned.

## Recommended starting model — October 29

Both apps retain Kokoro with Heart at 1.0× for fresh preferences. The shared model
picker now labels it **Kokoro (Recommended)**, with the quality/speed/memory
tradeoff explained in its details. Existing saved model choices keep precedence.
The recommendation fits the fixed picker column at the supported text sizes.
See [model selection](MODEL_SELECTION.md).

Fifteen focused shared/Libro/VoiceRelay tests pass, covering defaults, saved
choices and inert layout sizing. Static/documentation/tooling checks, both
workspace configurations and all four bundle audits pass. Evidence is under
`.local/kokoro-recommendation/` and
`.local/validation/release-5C907257-E505-45C2-BBE5-7D6A0F5A43C9/`.
Archives were skipped; GUI acceptance remains operator-owned.

## Shared fresh-start speech setup

October 28 consolidates both onboarding screens in NarrationUI's
`SpeechSetupOnboardingView`, using VoiceRelay's layout, installation explanation,
progress and primary actions. Libro retains Choose Custom Model Folder and preparation
details; VoiceRelay retained optional login startup in that revision. The October 29
unified concise setup revision above supersedes those app-specific content slots.
App-owned detection, cancellation,
verification/dismissal and existing model selections/cache remain unchanged. Synthetic
inert-view fixtures cover missing, busy, ready, cancelled and failed states without
running actions. Four shared fixtures and four VoiceRelay onboarding/retry/offline
fixtures pass. Debug and Release builds of both apps and all four bundle audits pass
(ad-hoc engineering signatures, embedded helper/resources and offline Metal probes).
Evidence:
`.local/validation/quick-50340149-243B-485F-83B0-6C1EB1355D86/summary.json`,
`.local/validation/quick-ADFE7223-00C4-4E96-BD71-0F58763146A2/summary.json` and
`.local/validation/release-537C9702-EA6A-4EE6-A3FF-3C16BB68D844/summary.json`.
The initial quick run (`quick-A57BE192-4997-44F1-87EB-87F3EDBDDA82`) stopped before
tests because Xcode's Metal shim missed the installed compiler. The passing runs
used the verified command-local `TOOLCHAINS=com.apple.dt.toolchain.Metal.32023.921.5`
selection documented in contributor setup; no component/model download or global
toolchain change was needed. Validation products remain in
`.build/WorkspaceDerivedData/Build/Products/{Debug,Release}/`, separate from the
running Xcode-built VoiceRelay app. Archives and the full fixture gate were not run
for this presentation-only revision. GUI/Canvas and real download/cancel/retry acceptance remain operator-owned through
L01/V01 in [the operator checklist](OPERATOR_VALIDATION.md).

## Libro whole-app review fixes

October 27 implementation addresses source-folder output protection, exclusive
atomic publication for unapproved destinations, persistent validated model/voice/
speed preferences, owned cancellable file drops and joined scanner replacement.
Shared queue admission validates names/collisions once; safety boundaries validate
the current target while refreshing source and inode protections, avoiding repeated
whole-batch planning and quadratic path-prefix comparisons.

The [implementation plan](LIBRO_REVIEW_FIX_PLAN.md) records the scope. The full
fixture gate passes, including 38 LibroCore, 328 VoiceRelay core and 166 app tests,
shared/static/packaging checks and the new source/publication/import regressions.
Existing private-document/native opt-ins remain skips. Evidence is
`.local/validation/full-C362DC1E-6FB1-4168-B1C5-143E6D4F0352/summary.json`.
Debug and Release workspace builds and four bundle audits pass. Products are in
`.build/LibroReviewFixes-20261027/Build/Products/{Debug,Release}/`; reports in
`.local/libro-fixes/` verify helper-only MLX, resources, codec, signatures and offline
Metal readiness. These are isolated ad-hoc engineering builds, with no installed
bundle replaced. GUI/listening, actual documents,
protected-file providers and signing-account acceptance remain operator-owned.

## VoiceRelay whole-app review fixes

October 26–27 implementation addresses all eight VoiceRelay review findings: exact
destination/path authority for retirement (including stale ledger intent),
cancellation when Publishing is disabled, targeted deletion-owner updates,
URL-based Reading List removal, original publisher metadata for archived articles,
HTML headline/slug preservation with PDF filename recovery, captured per-episode
pause assembly after helper/checkpoint reuse, and public transcript-link remapping.
Encoding version 3 rebuilds unfinished scratch from compatible lossless checkpoints;
completed and verified already-placed recordings stay unchanged.

The [implementation plan](VOICERELAY_REVIEW_FIX_PLAN.md) records stages and evidence.
Focused regressions cover migration, source identity, pauses and disablement.
The October 27 follow-up also keeps failed
transcript-only removals visible and preserves their error in either deletion
order; listing history leaves corrupt ledgers untouched.
Reading List callbacks stop/join obsolete speech before purging, rebind a surviving
duplicate's source association and admit replacement URLs even during active work
or after the old URL failed earlier in the session. Failure suppression follows
source URLs, not reusable Safari entry IDs.

The final full fixture gate passes, including 328 VoiceRelay core tests, 166 app
tests and all shared/Libro/static/packaging suites. Existing opt-in private/native
cases remain skips. Evidence is
`.local/validation/full-0F216836-5CB5-47F8-8A04-E9E1113F9997/`.
Debug and Release workspace builds and all four bundle/signature/resource/Metal
audits pass for the final source. Ad-hoc candidates use
`.build/VoiceRelayReviewFixes-20261026/Build/Products/{Debug,Release}/`; build/audit
logs are under `.local/review-fixes/`. Final static/documentation checks also pass.
No live library, service or installed operator app has been modified.

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

## Voice-selection rows — October 29

Both apps now use the supplied row-based template through the shared
SpeechModelControls: Model (with download/delete, size and info), Voice,
model-specific options and Play Sample. All rows are left-aligned with uniform,
text-size-aware spacing. Picker frames explicitly align to the leading edge.
Kokoro's speed value and Stepper stay together in the value column. Qwen's
Native/Language/Delivery rows initially shared that alignment. The current
revision above replaces Native with language-menu emphasis; Chatterbox import
remains a full row beneath Voice. Unsupported parameters are omitted.

Play Sample is inside the shared component, with app-owned playback/enabled state
and callbacks; separate app-local sample columns/rows are removed. Active options
and Sample originally flowed together with reserved space afterward to keep the
outer panel height steady. The later compact-height revision above removes that
reservation and tightens spacing while preserving the common menu anchors. Input
and sample enablement remain separate, preserving VoiceRelay's bundled playback
while model controls are busy. Existing parameters, recorded audio and cache
management behavior remain unchanged.

Eleven shared tests and six VoiceRelay integration tests pass. Offscreen checks
compare all five models at four text settings and three input/playback states
(60 inert layouts), verify stable envelopes and enlarged text sizing, and compare
compact versus labelled speed-control measurements. They open no app windows,
read no real model/profile storage and invoke no actions. Static/tooling/docs pass
in `.local/validation/quick-F64AE9A8-DB8C-4E70-A888-DCD2A2FFED8D/`.
Final Debug/Release workspace builds and all four bundle audits pass in
`.local/validation/release-31A3C5C4-2FA1-4142-BDD2-CE3A9729B5DA/`.
Archives are unrequested; GUI/keyboard/listening acceptance remains operator-owned.
Current ad-hoc candidates are
`.build/WorkspaceDerivedData/Build/Products/Release/Libro.app` and
`VoiceRelay.app` in the same folder, with parallel Debug products. Private final
logs/source digests are in `.local/model-controls-rows/`. The earlier
`release-5FF2259C-E2DC-4300-83E6-2A4FC0AD2598` pass preceded the final explicit
picker alignment; it is not the final-source receipt. No installed app or actual
model cache was replaced by validation.

## Stable model-selection layout — October 28

Both apps now pin Model and Voice to common, text-size-aware native Grid columns.
Chatterbox uses the same visible Voice label and menu position while retaining
reference-voice accessibility context. Storage action, size and details also use
stable columns. That revision used a hidden, inert set of supported parameter
variants to reserve the largest natural parameter area below the common menus.
The October 29 compact-height revision above removes that reservation. Errors can
still expand below the controls rather than being clipped.

That revision anchored the header to its leading edge and top-aligned sample and
output columns; the October 29 row template above supersedes the sample column. Fixed field/sample widths prevent model changes from selecting a
different narrow-window layout. Speaking parameters, saved choices, files and model
installation/deletion behavior are unchanged.

Ten shared presentation/storage tests and six VoiceRelay integration regressions
pass. One offscreen synthetic layout case measures all five models at 80%, 100%,
200% and an accessibility text size, verifies equal normal panel dimensions across
models and verifies enlargement at 200%, without invoking actions, opening app
windows or reading real model/profile storage. These measurements are component
regressions, not full-app GUI acceptance. Static/tooling/docs pass in
`.local/validation/quick-2D15ECD7-2C8D-4861-A67E-923834D2708B/`.
Both workspace configurations and all four bundle audits pass in
`.local/validation/release-73975CC1-95CB-4299-8F65-AC2B74CF3B81/`.
Archives were explicitly unrequested for that revision. Those receipts predate
the row template above; private logs/source digests are in
`.local/model-controls-stable/`. GUI, keyboard and
listening acceptance remain operator-owned; no installed app was replaced.

## Compact shared model controls — October 28

Both apps now use the same compact model row: an icon-only Download action becomes
trash when cached model files are present, local/estimated size sits beside it,
and the trailing ⓘ opens the description and generation-speed/narration-quality
meters. Inline stats cards are removed. The details popover retains Download
missing files for repair or additional language resources without deleting weights.

Selected-cache inventory runs off the UI actor and refreshes after installation,
deletion, selection/folder changes and app activation. Late or interrupted scans
cannot enable actions for the wrong selection. Confirmed deletion uses the existing
app-owned maintenance task and shared storage lease; in-use failures keep the
cached model, and imported folders remain read-only. Original recordings,
reference voices and unrelated repositories remain protected. No user cache or
installed app was modified during validation.

The compact-control revision passed nine shared UI/storage-state cases, eight native
storage fixtures and six VoiceRelay Settings/integration cases. The opt-in actual
model-generation case is skipped; audio generation was unchanged. Static/tooling
checks pass in `.local/validation/quick-F6C971A5-8361-441A-B5B4-99E1CAE65AAB/`.
Both workspace configurations and all four bundle audits passed for that source
in `.local/validation/release-80BB9C83-7252-4D54-9617-F5DA45AC940F/`.
Those receipts predate the stable-layout revision above; archives were unrequested.
Private logs/source digests are in `.local/model-controls-compact/`. GUI, keyboard and
real-cache acceptance remain operator-owned.

## VoiceRelay Voice Model Settings — October 28

VoiceRelay now has General, Voice Model, Pronunciation, Publishing and
Troubleshooting panes. Voice Model owns model/voice/speed selection, Download,
guidance, samples, installed-model storage and offline setup checks. These controls
are removed from Articles and General. Speech warnings and onboarding direct users
to Voice Model. The Settings window has a 540×680 ideal size with adaptive compact
navigation at narrow widths. Both apps now use the compact shared model row
with download/delete and size; the trailing ⓘ opens model details and meters. Existing preferences and captured jobs are
unchanged.

The original tab relocation, before the compact controls above, passed six
VoiceRelay regressions and four shared UI cases. Static/docs and tooling passed in
`.local/validation/quick-65CD8E02-E03D-4BF4-9E2A-32B43928AA48/`.
Both workspace configurations and all four bundle audits pass in
`.local/validation/release-1E11AF54-4FAF-4DEE-9602-19753D9E5393/`, with archives
explicitly unrequested. Those receipts predate the compact-row revision above;
GUI/keyboard acceptance remains operator-owned. Private evidence is in
`.local/voice-model-settings/`; the earlier cache/native receipts below retain
their original scope.

## Model controls and shared cache — October 28

Both apps now use icon-only download/delete, adjacent size, and an on-demand
model-details/meter popover. Inline stats panels and repeated Settings pickers are removed.
VoiceRelay selection/preview controls live in Settings → Voice Model; Libro keeps its main
batch controls. Section help is shorter while retaining consequential privacy and
deletion information.

New installations use the pinned HuggingFace library's standard shared cache;
explicit custom storage choices and legacy workspaces remain supported. Models
settings (Libro) and Voice Model (VoiceRelay) list downloaded models, allocated disk
sizes and confirmed deletion, plus folder override/default controls. Read-only
imports remain separate. Shared read leases cover complete sessions/installations;
deletion needs exclusive access and preserves audio, references and unrelated
repositories. See [model storage](MODEL_SELECTION.md#model-storage).

Fresh offline standard-cache installation, speech, snapshot-integrity and deletion
checks pass for Kokoro, Qwen, Chatterbox and Orpheus. These opt-in checks use copied
public model assets in temporary caches, shared background inference admission and
network-denied helpers. The user's actual cache and open Libro build were not
modified. Fresh installation also exposed nondeterministic JSON key ordering in
SDK-generated tokenizers; pinned structural digests now validate identical content
without relying on object-key order. Remote input hashes and acoustic identities
are unchanged. Evidence is under `.local/model-storage-validation/`.

The model-storage implementation’s full fixture gate passed at
`.local/validation/full-E43F4723-68B2-459B-906D-9EC223F17325/`. Storage migration
is one-time: explicitly selecting a former automatic folder afterward persists
across relaunch. Default-cache installs keep the override unset, while custom
folders remain explicit. Routine validation now supports `--skip-archives`,
retaining both workspace configurations and their four bundle audits; archive
checks remain available for distribution changes and explicit release validation.

The model-storage implementation’s Debug/Release builds and four bundle audits passed in
`.local/validation/release-DBD0321A-79CD-4A41-8565-751307F17B1D/`.
Archives were explicitly unrequested for that snapshot. Ad-hoc app
candidates are `.build/WorkspaceDerivedData/Build/Products/Release/Libro.app`
and `VoiceRelay.app` in the same folder (with parallel Debug products).
The earlier `release-8A90EA8C-0298-457D-B01D-F06048025A65` archive gate passed
before the final preference cleanup; those archives are historical, not the
current candidates. GUI/accessibility and signed release acceptance remain open.

## Shared model integration — October 27–28

Both apps now share Qwen3-TTS 1.7B CustomVoice (nine presets/ten languages),
Chatterbox Turbo (default and local immutable reference voices) and Orpheus 3B
(eight English presets), while retaining existing defaults and Kokoro/Soprano
behavior. NativeSpeech owns pinned primary/auxiliary inventories and static
speed/quality guidance; NarrationUI owns the common controls. Queued articles
capture the full model/voice/language/style selection. The [model guide](MODEL_SELECTION.md)
describes installation, previews, RAM requirements and reference backup limits.

The final full fixture gate passes: shared tests, 38 LibroCore tests, 331
VoiceRelay core tests, 166 app tests, pinned patch checks and packaging/static
regressions. Existing private-document/native opt-ins remain reported skips.
Evidence is `.local/validation/full-EB8A4A13-7243-4038-9C97-B2E0E7854A74/`.
Native short checks passed all 18 new presets, ten Qwen languages and a synthetic
Chatterbox reference. The original 29 sample files/manifest records are unchanged;
18 production-path English samples bring the catalog to 47. Native receipts are
under `.local/multi-model-implementation/`.

Debug and Release workspace builds, both app Archives and all six bundle audits
pass for the coordinated working tree based on `c10135f`. Evidence and isolated
ad-hoc engineering candidates are in
`.local/validation/release-CF376C4F-5242-41A5-8105-B4247F18C718/`.
Each archive contains `Products/Applications/<app>.app`; no installed app was
replaced or launched. The final Libro preview fix stops recorded samples as well
as live previews when language/delivery settings change. The standalone benchmark
passes 26 isolated tests and rebuilds with the raw Chatterbox PCM policy.

Offline preparation and multi-paragraph narration pass through both archived
helpers for Ryan, Chatterbox default and leah. Packaged contention confirms
interactive Qwen precedes waiting background Orpheus, at most one helper is
resident, and waiting cancellation publishes no audio. Logs, prepared plans,
worker hashes and synthetic recordings are in
`.local/multi-model-implementation/native-packaged-*`; the aggregate
`summary.json` records all gates. These bounded passages do not establish
hour-long memory stability or linguistic/listening quality.

Large helpers are reaped between utterances under the existing admission lease;
reload and hash-validation overhead exceeds warm benchmark-call costs. Chatterbox
now preserves raw vocoder PCM by disabling inherited SDK normalization/fade;
original benchmark recordings retain their old processing and bytes. See the
[integration record](MULTI_MODEL_TTS_IMPLEMENTATION_PLAN.md) for design and evidence.
Long-form linguistic quality, GUI/accessibility, actual documents, normal-signed
installed apps and live delivery/player checks remain operator-owned.

## Standalone TTS model comparison

On October 27 the operator reported Qwen3-TTS 1.7B / Ryan as the top bracket
choice, Chatterbox Turbo / default as runner-up, and Kokoro / Heart plus Orpheus
3B / leah as contenders. The [shared integration record](MULTI_MODEL_TTS_IMPLEMENTATION_PLAN.md)
covers all supported preset voices of the selected checkpoints, shared setup/UI,
native adapters, resource admission and both app workflows. The implementation
is described below. This records the supplied ranking without inventing or importing
canonical bracket votes; held-out and long-form listening remain open.

October 24–25 implementation adds the [Swift benchmark utility](../tools/TTSBenchmark/README.md),
independent of either app. It explicitly prepares pinned model assets, supervises
serial offline workers with time/memory bounds, preserves native-rate audio and
records timings, output hashes and durable attempts. A resumable blind model/voice
bracket precedes separate held-out and long-form finalist confirmation.
Cold/warm loads and product-reference variants are timing evidence, not additional
listening entrants. These October 24–25 observations precede the October 27
product integration; the original benchmark artifacts remain unchanged.

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
and measurement limits. No operator ranking was recorded at that benchmark run's
creation. The later reported ranking is recorded above; operator
[M01](OPERATOR_VALIDATION.md#model-evaluation-developer-utility) still requires
finalist held-out/long-form acceptance. New product model support remains planned.

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
startup uses the platform service API. The October 29 startup revision above changes
fresh configurations to a one-time default-on request with the control only in
General Settings; existing choices remain intact. Keychain behavior, system approval and reboot/login
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

The October 20 monorepo validation established the migration baseline:
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
