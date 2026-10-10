# Validation evidence

Current documentation was reconciled October 10, 2026. Entries below record what
was checked at their stated date; older UI names, commands, signing results and
limitations are historical evidence, not current operator instructions. Use
[README](../README.md), [beta checks](BETA_TESTING.md),
[UI acceptance](UI_ACCEPTANCE.md) and [server recovery](SERVER_RECOVERY.md) for
current workflows. The newest code-validation results precede the older entries.
Documentation-only checks are recorded separately and are not a new app build.

## October 10: hide idle workspace status

The workspace footer and its divider now appear only during owned speech,
stopping or publishing work. Healthy Publishing confirmation, No Ready articles
and retained completion/stop messages no longer occupy the idle workspace.
Setup/recovery and error notices remain in their existing locations; Generate
Audio retains its disabled-reason tooltip. No publishing or queue behavior changed.

- Swift app compilation and **four focused app checks passed**, covering idle
  visibility across all sidebar destinations, active speech/stopping/publishing,
  credential-free setup/error readiness and inert native control construction.
- Documentation checker passed: 16 Markdown files and 70 local links/anchors;
  `git diff --check` passed. GUI layout and transitions remain operator-owned;
  no Xcode build or live-service acceptance was performed for this presentation change.

## October 10: website filter count ordering

Articles/Queue Website choices use current-scope counts, highest first, then
case-insensitive alphabetical ordering for ties. All Websites remains first.
Unknown Website uses the same ordering; an empty selected website remains available
with count zero. Existing host grouping, row order and selections are unchanged.

- Swift app compilation and **three focused website-filter tests passed**, including
  grouped host counts, equal-count alphabetical ties, independent scope counts,
  Unknown Website, zero-count selection, live count changes and retained-job counts.
- Documentation checker passed: 16 Markdown files and 70 local links/anchors;
  `git diff --check` passed. No Xcode build, GUI or live-service checks were needed
  for this model-only ordering change; dropdown appearance remains operator-owned.

## October 10: concise tooltips and offline Help

Section ⓘ hover text is now a short About label; VoiceOver hints describe the
activation rather than duplicating the full explanation. Settings popovers and
control tooltips were shortened while retaining removal and privacy consequences.
Publishing/backup popovers offer More Help, and the shared native Help menu opens
typed, static Publishing and Uploads / Library Backup and Restore guide windows.
No library, authentication, network, publishing or deletion operation was changed.

Validation:

- **Six focused app-model checks passed**, covering typed topic restoration/rejection,
  unique guide section identity, static Help view construction, Settings, workspace,
  publishing/automation and backup controls. Tests used inert/isolated models.
- **Unsigned Xcode Debug build passed** (`CODE_SIGNING_ALLOWED=NO`), including
  the shared Help commands and typed Help window scene. The existing AppIntents
  metadata-extraction notice remains; no app was launched.
- Documentation checker passed: 16 Markdown files and 70 local links/anchors;
  `git diff --check` passed.
- Native menu placement, popover/window rendering, keyboard navigation and VoiceOver
  remain manual acceptance in UI_ACCEPTANCE.md, section 7. No GUI or live service
  acceptance was performed.

## October 10: explicit local discard and original-website filters

Uploads hides its redundant Review Uploads control when already open and offers
per-row × for local-only removal. Explicit discard preserves server media/feed
proofs and retained text, writes durable intent before unlink, cancels a matching
native queue job atomically, and suppresses automatic regeneration/transfer.
Changed temporary bytes are removable only in the owning library's recorded
folder; legacy storage keeps original-byte checks. File replacement and symlink
fixtures retain the file and an item notice. Manual generation can create fresh
output; discarded copies cannot win automatic local/server conflicts.

All Articles/Queue have independent Website filters and counts. Foundation URL
parsing/IDNA plus the requested www display alias groups equivalent HTTP/HTTPS,
case and trailing-dot hosts while keeping other subdomains separate. Filters
preserve sort order/source identity and restrict selection actions to visible
rows. Website counts are aggregated in one pass, with no network lookups.

Validation:

- Focused initial checks: 4 core and 3 app tests passed, covering discard/relaunch,
  server preservation, changed legacy files, substituted files, manual regeneration,
  app ownership/review guards, IDNA and website-filter selections/order.
- Broader regression: **89 selected core checks and all 105 app-model tests passed**,
  including publishing, recovery, storage/removal, project references and lifecycle.
- Final interruption audit added atomic matching-queue cancellation and excluded
  discarded local replacement candidates. Its first check caught a nested SQLite
  transaction in the new code; direct record update corrected it. **Final 30 core
  and 3 app checks passed** after that correction.
- Final unsigned Xcode Debug build passed (`CODE_SIGNING_ALLOWED=NO`). The
  existing AppIntents metadata-extraction notice remains. No app was launched.
- Documentation checker passed: 16 Markdown files and 70 local links/anchors;
  `git diff --check` passed.
- GUI, Canvas rendering, live Keychain/server and listening acceptance were not
  run. Operator steps are in UI_ACCEPTANCE.md, section 6.

## October 10: automatic reconciliation and conflict resolution

Publishing now reconciles server state automatically before queued generation and
through its normal drain. The Check Server Audio/review/apply UI and its automation
pause were removed. Exact original identities or unambiguous retained links match
articles; hash/size, actual duration, format and full decoding verify media.
Comparable longer valid audio wins, while ties and known voice/speed variants keep
the server copy. Local replacements use new media identities and retain the losing
server file. Interrupted media uploads and complete server copies skip redundant
TTS/PUT. Explicit retirement and the restored-library review gate still take precedence.

Per-item errors preserve existing feed entries and mark only affected rows for
attention while unrelated work continues. A whole-feed failure blocks feed writes
and deletes while permitting independent fresh media uploads. Sanitized notices
are retained even before an empty library has a database. Tool availability,
startup, cancellation and deadline errors are not evidence of damaged server audio.
Cached proofs, five-minute cadence/backoff, conditional reads, strong validators
and representation digests reduce repeated work. Unrelated RSS metadata changes
reuse unchanged per-item hash/size proofs; forced retries check current media. Unchanged records avoid redundant
SQLite updates; the obsolete whole-library review fingerprint and orphan directory
listing were removed. Fresh empty libraries no longer write an empty feed before
any episode exists. Cleanup retains substituted local bytes after a server winner.

Validation:

- Final complete regression run: **78 core tests and all 101 app-model tests passed**,
  covering delivery, automatic reconciliation, comparable/damaged copy selection,
  partial publication, whole-feed and per-item failures, metadata-only cache reuse,
  forced verification, actual synthetic AAC decoding, unavailable/deadline tools,
  temporary cleanup, server removal, backup/restore, project references and
  existing app lifecycle/UI-model behavior.
- Final focused runs also passed **32 core + 4 app tests**, then **26 core + 2 app
  tests** as tool-error, empty-library diagnostics and stale-row logging were refined.
  The complete run above includes the subsequent per-item cache optimization.
- **Final unsigned Xcode Debug build passed**, CODE_SIGNING_ALLOWED=NO, using
  existing pinned package checkouts. AppIntents metadata extraction was skipped
  because the app has no AppIntents dependency; that existing warning remains.
  The initial sandboxed attempt could not write Xcode's package manifest cache;
  the permitted build with required cache access succeeded. No dependency pins
  changed, and the preexisting workspace lockfile mirror was restored.
- Documentation check: **16 Markdown files, 70 local links/anchors passed**;
  git diff --check passed. Third-party licenses/notices were not changed.
- Private ignored logs: `var/validation/2026-10-10-automatic-reconciliation/`.
  Intermediate fixtures exposed nested transaction handling, stale assumptions
  about in-memory GET responses/empty-feed writes, and header capitalization;
  those issues were corrected before the passing runs above.

These are isolated fixture/build checks. No live library, credentials, Safari,
server share, speech model or GUI was accessed. See [operator acceptance](SERVER_RECOVERY.md#operator-acceptance)
for signed-app synchronization, public mapping and Overcast playback tests. Audio
comparison uses duration as a completeness heuristic, not proof of every narrated
paragraph; legacy voice metadata and servers without strong feed validators retain
explicit limits documented in that guide.

## October 10: documentation reconciliation and pruning

README, the architecture/handoff/roadmap, article/runtime guides and operator
checklists now describe the current app, automatic processing, fixed media layout,
temporary-output cleanup and explicit server reconciliation. The new architecture
guide replaces the conflicting prototype brief; the completed checkout-migration
guide was removed. The approved UI contract was condensed, with comparison studies
explicitly labeled as the October 9 design record rather than a current app mirror.

Pruned retired agent, retention, sample-speech and beta layout-probe runbooks and
redundant design/publication-preparation entries from this validation log. A short
retired-foundation summary preserves evidence boundaries; original details remain
in repository history. Dependency license texts and reproduced third-party notices
are unchanged. Acknowledgements now provide local navigation and distinguish the
upstream notice's relative links/baselines from VoiceRelay's actual dependency pins.

Documentation-only validation:

- Checked **16 Markdown files and 69 local links/anchors**. Reproduced upstream
  notice links were resolved against the existing pinned dependency checkout;
  its notice still matches byte-for-byte.
- Design-study static checks passed for both HTML files, JavaScript syntax,
  synthetic transitions and **69 generated markup fixtures**; no browser/network
  or native rendering was performed.
- The existing diagnostic CLI's help matches documented options. The explicit
  synthetic Reading List command reported **2 entries, 0 skipped**, without
  protected-file access, speech, live-state adoption or server operations.
- git diff --check passed. No application/runtime source changed in this pass,
  so builds and speech/network suites were not repeated. Code results and remaining
  manual acceptance below retain their original dates.

## October 10: server reconciliation and prototype cleanup

Publishing now provides an explicit, read-only Check Server Audio review followed
by Use Verified Server Copies. Recovery parses bounded authenticated RSS, matches
original article identities or unambiguous legacy links, streams SHA-256 and
checks exact media length. Applying verified copies restores history, rekeys
legacy GUIDs and removes duplicate queue work. Interrupted media uploads can
reuse their copies while leaving feed publication pending. Unknown files are
counted where listing is supported, never guessed from titles or adopted blindly.
An existing feed blocks unconfirmed-destination publishing before any remote
write. Recovery review pauses automation, preserves unconfirmed local bytes and
rejects changed destinations, stale plans and conflicting media. An unchanged
Reading List refresh does not invalidate a plan. Cancelling authentication
replaces its invalidated context so an explicit retry has a fresh context.

Removed the inactive agent executable, XPC contract/client, agent diagnostics UI,
LaunchAgent packaging/embedding and agent-only tests, plus standalone AppKit/UI
repro projects. Active CLI, core fixtures, speech helper and compatibility storage
paths remain. The signed-agent stripping warning's build input no longer exists;
no strip/sign workaround or security-policy relaxation was introduced. Packaging
also removes an obsolete generated app wrapper before rebuilding if it still
contains that agent. No live app, preferences, library or remote state was changed
by this validation. The project bundle identifier change can explain apparent
preferences loss; Derived Data is not the persistent library location.

Validation:

- Final focused run: **18 core tests and 5 app tests passed**, including recovery,
  credential cancellation/session behavior and unique Xcode project references.
- Earlier regression runs passed **64 core delivery/recovery/origin tests plus
  3 app recovery tests**, and separately **16 core backup/runtime/origin/WAL
  regressions plus all 102 then-current app tests**. Later recovery edge cases and
  cancellation changes were checked by the final focused run; these counts are
  not a claim that a full suite was rerun after every edit.
- **Unsigned Xcode Debug build passed**, CODE_SIGNING_ALLOWED=NO, with no agent
  product or LaunchAgent embedded. The normal AppIntents metadata-skipped warning
  remains. This establishes compilation/linking, not signed-app acceptance.
- Project/Info.plist lint, build-script shell syntax and git diff --check passed.
  Xcode/SwiftPM removed the tracked workspace Package.resolved mirror during
  resolution; restoring the existing pinned mirror and using existing package
  checkouts resolved the initial build-tool failure without changing dependencies.
- Private logs are ignored under
  `var/validation/2026-10-10-server-recovery-cleanup/`. An initial cancellation
  fixture incorrectly expected no preexisting settings ledger; its assertion was
  corrected to require unchanged bytes, and the final fixture passed.

Signed build, native UI/Canvas, real Keychain prompts, protected Safari access,
live DAV recovery/public mapping and Overcast remain operator acceptance. Follow
[SERVER_RECOVERY.md](SERVER_RECOVERY.md). The retired-foundation summary below records historical limitations, not
current product behavior.

## October 9: consistent article origin and saved date in Server Audio

Server Audio now shows the same original-website / localized Saved-date line as
All Articles, Queue and preparing rows, through a shared ArticleOriginLine and
ArticleOriginMetadata. Duration/size and publication/removal status remain separate.
The saved date is Reading List metadata, never the generation/publication date;
missing dates stay omitted. Queue prefers its captured saved date when available.

Episode has an optional, backward-compatible originalSourceHost, captured on
admission and publication independently of existing RSS sourceHost/sourceURL.
Read-only episode loading recovers older origins from original-source inventory
identity or an integrity-checked, identity-matching snapshot, without fetching or
rewriting records. Undated inventory entries still provide a host. If original
metadata cannot be recovered, presentation can use existing source metadata; it
never fabricates a date. Temporary-output requeue retains the original host.
No SQL schema migration, audio policy/model math or RSS link change was made.
The synthetic Server Audio preview includes the new line. Earlier work is retained.

Validation:

- **20 focused Swift tests passed** across three serial runs: 15 core and 5 app.
  New cases cover read-only inventory/snapshot recovery, corrupted/mismatched/
  absent snapshot refusal, original host capture before redirected-source speech,
  compatibility/round trip, shared labels and missing-date omission. Existing
  saved-date RSS ordering/recovery, origin RSS fields, backup/restore, temporary
  cleanup/regeneration, queue host and union/view regressions also passed.
- **Unsigned Xcode Release build passed** with CODE_SIGNING_ALLOWED=NO. This is
  compilation/linking evidence, not a usable signed app or Keychain acceptance.
- Signed Release packaging was attempted and failed: Xcode reports its selected
  development certificate invalid. A read-only trust-service check of the prior
  dist app reports CSSMERR_TP_CERT_REVOKED. Public certificate comparison confirms
  Xcode selected the available development identity, whose date range has not
  expired; no certificate/Keychain/account/profile changes were made. This is an
  external signing blocker. dist/VoiceRelay.app remains the previous stale build
  and is not a test artifact for this update.
- git diff --check passed. Logs are ignored under
  var/validation/2026-10-09-article-origin/. An initial test-only Swift Testing
  macro compile error was fixed by evaluating throwing lookups before #require;
  all final focused checks passed. Full suites/Python were not rerun.

Operator next steps: replace the revoked development certificate and update the
matching signing profile/local configuration, then run
`bash scripts/build-app.sh release`. After a successful signed build, compare an
older episode, a new item and a redirected/archived article in All Articles,
Queue and Server Audio. Check the website and Saved date match their original
source; an undated item must not display its audio generation date as Saved.
GUI/Canvas, Keychain unlock, listening and live server acceptance remain manual.
No live library/source/preferences/feed/server was changed by this validation.

## October 9: approved Unified articles / Publishing native implementation

Implemented the user-approved design in the existing SwiftUI app source files.
Articles now has All Articles / Queue scopes alongside Server Audio. The typed
source/episode/preparation union retains every job, groups duplicate sources in
All Articles, orders newest saved dates independently from Queue FIFO, preserves
separate selections and exposes retained absent-source jobs. Manual Add omits
already-queued/preparing sources without introducing a history exclusion rule.
Membership removal retains Reading List entries and snapshots; ordinary row
metadata changes do not disable unrelated row removal or Generate/Reset.

Publishing replaces visible Delivery terminology, preserving internal identifiers,
persisted settings and credential behavior. Setup/off/attention/unknown notices
route directly to Publishing; configured presentation is passive channel context.
Readiness reads cached metadata only, never Keychain/network. Missing publishing
is not a speech blocker. Restore review takes precedence and additionally blocks
manual admission/queue mutation controls, including direct preparation removal.

Native toolbars, scope picker, focused list Delete/menu actions, Cmd-Shift-G
Generate and Cmd-Period Stop use existing availability gates. Measured speech
progress remains visible with pending admissions; publishing is separate and
terminal progress clears. Settings retains its dimensions and glass selection
strip, adds a Reduce Transparency fallback, puts everyday preferences first when
ready, wraps credential controls and exposes a full selectable subscription URL.
Connection failure text wraps instead of being limited to two lines. Legacy Finder
actions no longer add glass per row. New named previews are synthetic and inert.
No core schema, audio policy, TTS math, dependency or project.pbxproj change was
needed for this UI continuation. Earlier uncommitted beta work was preserved.

Validation for the final source:

- Complete **VoiceRelayAppTests: 102 passed**, serially, with local Swift/module
  caches and `--disable-sandbox --skip-update --no-parallel`. Ten new focused
  tests cover union ordering/duplicates/absent sources, typed selection namespaces,
  eligibility, preparation transfer, all five cached Publishing states with zero
  credential calls, review-gated actions, per-row metadata independence and actual
  isolated membership removal retaining source/snapshot/other selection.
- Signed **Debug and Release builds/packages passed** using
  `bash scripts/build-app.sh debug` and `bash scripts/build-app.sh release`.
  Both passed `codesign --verify --deep --strict` with macOS trust services.
  `dist/VoiceRelay.app` contains the Release build. No app was launched.
- `git diff --check` and ignore checks for generated app/log artifacts passed.
  Core/Python code was unchanged by this UI work; those suites were not rerun.
  Earlier full beta results remain separately recorded below.

The first broad test pass found two assertions in one admission test that assumed
an already-queued source could be re-added to clear another source's issue. The
approved eligibility behavior makes that Add a no-op; the updated regression now
asserts no duplicate/fetch and retention of the unrelated issue. A preview-only
attempt to set the read-only Reduce Transparency environment failed compilation;
the unsupported preview override was removed, while the real environment reader
and fallback remain. Sandboxed Xcode initially could not write its manifest cache,
and sandboxed deep verification reported CSSMERR_TP_NOT_TRUSTED; authorized builds
and read-only trust-service checks succeeded. These were tooling limits, not
source/signing defects. Logs are ignored under `var/validation/2026-10-09-ui/`.

No GUI/Canvas rendering, keyboard/focus, VoiceOver, appearance, protected Safari
input, real speech/listening, Keychain unlock, live publishing/removal or Overcast
acceptance was performed. No live library/preferences/source/server was migrated
or changed by validation. Use [UI_ACCEPTANCE.md](UI_ACCEPTANCE.md) for the manual
native UI pass and BETA_TESTING.md for broader beta acceptance.

## October 9: dependable daily-use beta preparation

Implemented portable explicit speech setup and private library backup/restore,
plus a consolidated roadmap/handoff and BETA_TESTING.md operator checklist.
Original-level 96k AAC, pinned model math, one inference worker, publication
behavior and source read-only policy are unchanged. Optional archive recovery
has a private CLI capture path (`review-url --use-archives [--saved-at ISO8601]`)
for the operator's real failing-article corpus; no site-specific extraction rule
was invented without a demonstrated source failure.

Speech setup bundles five immutable Python/helper/pin files in a resource-only
Swift target. General installs explicitly into the private app-managed runtime
root, preserves explicit/legacy runtime selection, checks offline and supports
Cancel/Quit. Prerequisites remain python3, uv, ffmpeg and ffprobe; these external
tools are not bundled or installed globally. Installer children share an isolated
process group, and cancellation is joined. Failed verification of the selected
runtime blocks processing. No automatic build/startup/readiness download exists.

Backups contain SQLite state/snapshots, optional private delivery ledger and a
hashed versioned manifest. They use SQLite backup, not raw copies of a WAL
database, validate tables/records/snapshot integrity, reject links/unknown files,
use owner-only output and refuse overwrite. Apple's SQLite retains a stale -shm
after a destination switches to DELETE mode; the newly owned destination is
closed and its unneeded sidecars removed before manifest commit. A fixture
verifies that committed WAL records survive in the standalone database.
Credentials, preferences, model assets, audio and scratch are excluded.

Restore stages/remaps into controlled target storage, clears disposable chunks,
preserves GUID/date/voice/text and failed rows, and re-readies interrupted rows.
The current SQLite connection closes before atomic directory exchange while its
writer lease remains held; the previous library is retained beside the current
one. Failed pre-commit validation preserves current state. A persistent review
gate blocks speech, automatic admission, delivery, server removal and local cleanup
across relaunch until Finish Library Review. Automatic preferences remain off.
CLI restore accepts only an explicit new destination. No restore was performed
against the user's library; all round trips used isolated synthetic fixtures.

Validation:

- Baseline full Swift suite: **241 core + 88 app = 329 passed**. Baseline Python:
  **22 passed**. Final full Swift run: **249 core + 91 app = 340 passed**. After
  the final app-only persistent review-gate addition, the complete app suite was
  rerun: **92 passed**, giving final coverage of **249 core + 92 app = 341**.
  Core/source/runtime code was unchanged after the full core run. Final Python:
  **22 passed**. New coverage includes WAL/standalone export, offline text reuse,
  relocation/remapped metadata, corruption/link/overwrite/worker refusal, failed
  and interrupted rows, cancellation, private settings isolation, inert controls,
  bundled setup outside the checkout and review-gated local cleanup across relaunch.
- Signed final **Debug and Release build/package passed** with
  `bash scripts/build-app.sh debug` and `bash scripts/build-app.sh release`.
  Deep/strict signature checks passed for both bundles. All five packaged setup
  files match the current source hashes; no Python caches were packaged.
- CLI help exposes the new archive/backup commands. Plist lint, shell syntax,
  `git diff --check` and ignore probes for private backup/signing/log artifacts
  passed. No project.pbxproj edit was needed; both existing project tests passed.

Commands used project-local Swift/module caches with `--disable-sandbox
--skip-update --no-parallel`; Python used `python3 -m unittest discover -s
runtime/kokoro/tests`. Logs are ignored under `var/validation/2026-10-09-beta/`.
Known deprecated --skip-update and inaccessible user-cache warnings remain;
they did not fail validation. No GUI/Canvas, protected Safari input, real model
inference/listening, model/runtime download, Keychain authorization, live article
fetch, feed upload/server deletion, live-state restore or service enrollment ran.

Operator next: quit the old app and run dist/VoiceRelay.app, then follow
[BETA_TESTING.md](BETA_TESTING.md). Test the private real-article corpus, real
managed installation/relocation, interruption and server/Overcast behavior,
and first an isolated backup restore before GUI restore. Milestone acceptance
remains pending those checks. This update can invalidate old unfinished helper
fingerprints once because setup-source bytes changed; published audio is preserved.

## October 8: direct Xcode signing repair

Reproduced a direct Debug build failure: VoiceRelay and VoiceRelayCLI required a
development team. Publication cleanup had moved the private team setting into
ignored `Signing.local.xcconfig`, but only the packaging script loaded it.
Both project configurations now use `Packaging/Signing.xcconfig`, which optionally
includes that local file. Targets inherit the setting; no concrete signing
identifier enters shared source. The script uses the same project configuration.

Validation: direct `xcodebuild -project VoiceRelay.xcodeproj -scheme VoiceRelay
-configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath
"$PWD/DerivedData" -onlyUsePackageVersionsFromResolvedFile build` passed without
a command-line xcconfig override. Deep/strict signature verification of the Debug
app passed. Both focused Swift project tests passed: unique app-source references
and private-signing configuration for Debug/Release. Project plist lint, shell
syntax and whitespace checks passed; the local signing file and validation logs
remain ignored, and the local signing file retains owner-only permissions.
Logs: `var/validation/2026-10-08-xcode-build/`. No app launch, GUI/Canvas, live
article or feed activity was performed. Release was not rebuilt for this repair.

Operator check: reopen VoiceRelay.xcodeproj if Xcode has not picked up the project
change, select VoiceRelay → My Mac and build with ⌘B, then run with ⌘R.

## October 8: optional archived-article recovery

Added opt-in Archive.ph/Wayback recovery for new queue admissions and Article
Preview after an original fetch or validation failure. Recovery reads existing
captures only; no submissions, browser sessions, JavaScript or CAPTCHA bypass.
It retains the original source identity, saved-date RSS semantics and publisher
narration, while capture provenance is kept in private snapshots and shown in
Preview. Saved text is reused offline. Settings defaults off and documents URL
disclosure, tracking removal and exclusion of other queries/local hosts.
Provider requests have host-restricted HTTPS redirects, byte/deadline limits and
no retry loop. Failure retains the original issue with a safe unavailable notice.
New generic validation catches short subscription prompts and missing-page titles.

Research: JavaScript `archivetoday`, TypeScript `@agntn/archives`, Memento RFC 7089
and the official Wayback Availability API were reviewed before implementation;
see SOURCE_REVIEW.md for links and the dependency decision. No third-party code
or runtime dependency was added. The supplied RemovePaywall page was unavailable
to research fetches and no supported API was verified, so it is not integrated.
Public example.com protocol probes returned Archive.ph **200; application/link-format**
and Wayback **429**. Archive.ph's real TimeMap uses timestamped replay URLs;
fixtures cover those as well as short links. These probes verify protocol shape
and current endpoint availability, not recovery of the user's articles.

Validation: **40 core + 2 app tests passed (42 total)**. Coverage includes original-
first/opt-out behavior, status/login/subscription recovery, nearest-date capture,
raw Wayback replay, malformed/foreign metadata, timestamp and root normalization,
restricted redirects, privacy exclusions/tracking removal, CAPTCHA/size rejection,
cancellation, sanitized logging, saved-date/identity preservation, durable offline
reuse, publisher artwork/attribution and inert preview/settings integration.
Signed **Release build/package passed**, followed by deep/strict signature
verification; `git diff --check` passed. Logs and public protocol fixtures are
ignored under `var/validation/2026-10-08-archive-recovery/`. No GUI/Canvas, Reading
List read, user-article network request, live state migration, speech/listening or
feed upload was performed. The full Swift suite was not repeated.

Operator check: quit the old app and open dist/VoiceRelay.app; enable General →
Reading List → Try archived copies when articles fail. Re-select a previously
failed Article and Add to Queue. Confirm Ready, original source host, then speech
and publication normally. Preview the source to see provider/capture provenance.
Use opt-in debug logging to inspect fixed archive lookup/recovered/unavailable
outcomes. Also test an uncached or CAPTCHA-blocked article and Stop during fetch;
it must stay unqueued, with a safe issue or cancellation rather than cache chrome.

## October 8: Server Audio removal visibility and stale actions

The previous UI dropped rows immediately after local retirement, then its library
refresh restored pending server removals. A second action after remote confirmation
could reach an expired record with a cleared remote path before the UI refreshed,
producing the obsolete finalized-audio error. Fixed the transition rather than
hiding the error:

- Removal reloads durable history, keeping a row visible until server confirmation.
  Active local/server removal shows Removing… and disables that row's removal
  action. A failed remote operation remains Removal pending and can be retried.
  Reset/selection actions filter unavailable targets; stale UI actions are no-ops.
- Saved-audio refresh results and errors are guarded by a revision changed at
  removal boundaries and delivery completion, so older reads cannot restore stale
  rows or overwrite current removal state.
- Core removal treats explicitly completed local retirement (`expired` plus
  `manualAudioDeletionRequested == false`) as idempotent, both while its server
  removal is pending and after confirmation. Repeated requests do not rewrite the
  record/ledger or re-add a confirmed remote delete. Validation and identity checks
  remain for actionable media; unknown/corrupt/unfinalized records still fail safely.
- Explicit pending-removal Retry forces delivery past backoff, while a stale action
  after confirmation does not force a redundant upload. No live data was modified.

Validation: **16 core + 8 app tests passed (24 total)** using the focused serial
removal/history/upload-control filter. The new gated DELETE app fixture checks
continuous row presence, active-control disabling, repeated/stale actions, success,
failure visibility and manual Retry; the core fixture checks identical records and
ledgers before/after duplicate requests and zero subsequent network work. Existing
local removal, captured-ID reset, file safety, pending removal recovery and upload
control tests passed. Signed Xcode **Release build/package passed** and deep/strict
signature verification passed. `git diff --check` passed. Logs are ignored under
`var/validation/2026-10-08-server-removal-race/`.

Manual check: quit the previous app, open `dist/VoiceRelay.app`, and remove a
disposable Server Audio episode. Its row should stay visible as Removing… until
confirmation, then disappear once. Its remove control should be disabled while
active; a failed deletion should remain Removal pending and become retryable.
GUI/Canvas and live server deletion were not run by the agent.


## October 8: temporary output and Server Audio history

Removed General's Storage section, audio-folder bookmark/chooser, retention
preferences, age-policy enum/sweep and 15-minute maintenance task. The app uses
owned system temporary output; diagnostic fixtures still accept explicit isolated
folders. Persistent SQLite metadata and article snapshots remain private for
recovery. Server Audio replaces the screen/menu name and retains remote episode
history after local cleanup. Pending uploads and unfinished server removals stay
visible; removal updates the feed before deleting remote bytes.

Byte-confirmed media upload plus confirmed feed membership at the current
destination gates cleanup. Durable release intent precedes unlink; hash/size/file
identity are checked again at unlink. Finalization-complete metadata prevents a
periodic drain from deleting bytes during publication validation. Existing native
VoiceRelay copies follow the same confirmed-cleanup rule (user explicitly waived
preservation); unrelated files and Python/reference media are untouched. Missing
unconfirmed temporary output is requeued from retained snapshots, with failed rows
kept manual Retry. Released output recreates on destination changes using the same
GUID, publication date and captured voice. Local feed rendering no longer depends
on intentionally released copies. Idle cleanup avoids redundant database writes.

Delivery completion reloads history without immediately triggering another drain;
this prevents a failure/refresh retry loop while preserving manual and periodic
requests and retry backoff. Availability notices compare episode IDs so confirmed
remote-only history cannot hide an unavailable unuploaded local item.

Validation:

- Full serial Swift suite: **228 core + 84 app tests passed (312 total)** before
  the final existing-audio cleanup extension and completion-path refinements.
- After extending existing-audio cleanup: **38 core + 9 app focused tests passed
  (47 total)**. Coverage includes temporary generation, confirmation-gated
  cleanup, failed PUT/feed confirmation retaining bytes, changed-file refusal,
  crash-intent retry without network/credentials, finalization gating, retained
  history, remote deletion order, removal failure visibility, relaunch, GUID/voice
  recovery, changed destinations, legacy cleanup and unrelated-file preservation.
- Final app completion checks: **7 tests passed**, including the new no-immediate-
  retry-loop and mixed local/remote availability cases, plus publication during
  later inference, history/relaunch, upload controls and removal of legacy rotation.
- Signed Xcode **Release build/package passed**, and the completed app passed
  `codesign --verify --deep --strict`. No app launch, GUI/Canvas rendering, real speech/listening,
  live source read, upload, hosting cutover or live-file cleanup ran.
- Logs: `var/validation/2026-10-08-temporary-audio/`. `git diff --check` passed.

Operator checks:

1. Quit the previous app and open `dist/VoiceRelay.app`. Confirm General has no
   Storage section and the sidebar/menu now says Server Audio.
2. Generate a small test article with Delivery enabled. Wait for Published;
   verify it plays in Overcast, its row survives reopening/relaunch, and Upload
   New Items hides. The owned local M4A copy is removed only after confirmations.
3. Generate another test article. Confirm the earlier episode remains in the
   subscription. Disable Delivery for a new item, then re-enable it; unconfirmed
   temporary output stays available and upload completes normally.
4. Remove a disposable episode from Server Audio. Confirm feed removal and server
   audio deletion; a failed remote removal must remain listed as Removal pending.
   Do not expect old-host copies to be deleted when changing destinations.

Performance: the supplied partial log has finalizer wait **0.0 ms**, ready items
**0**, **17.866 s** encoding for **1217.800 s** audio (**0.880 s/audio minute**),
**1.445 s** assembly and approximately **8 s** subsequent media upload. Its final
GPU idle tail is consistent with finishing CPU encoding with no ready inference;
retain the single worker and unnormalized 96k AAC. The excerpt cannot establish
whole-queue throughput or earlier overlap, and cleanup has no claimed speedup.


## October 7: US/UK regional voice settings

Added Language & Region before the filtered Voice picker: US English defaults to
Heart with ten voices; UK English has eight and defaults to Emma. Menu order uses
upstream VOICES.md overall quality grades with stable alphabetical ties; that
source provides no per-voice popularity counts. Gender labels distinguish voices.
Region derives from the persisted voice ID, so legacy Heart/Bella/Emma preferences
decode unchanged. Switching regions selects its top voice; same-region selection
keeps the user's choice and speed. New admissions capture en-US/en-GB while
re-enqueue preserves previous settings. Preferences use the existing injected
UserDefaults store so fixture checks never need production preferences. A named
inert UK Settings preview supplements the default preview. Other languages,
model/runtime/dependency pins and unnormalized 96k encoding remain unchanged.

Validation:

- **49 core + 23 app-model/source tests passed (72 total)** with the focused
  queue/Kokoro/settings/preferences filter, serially. Includes region counts,
  grade order/ties, all 18 voice IDs accepted by configuration, Codable/legacy
  preferences, region switching, captured/re-enqueued choices, preference
  persistence, inert views/previews and existing queue/settings/helper behavior.
  The initial six focused tests also passed before this regression run.
- All **18 local pinned voice packs matched their provenance-manifest hashes**.
  This was metadata/file verification only: no model loading, inference or download.
- Signed Xcode **Release build/package passed** and `dist/VoiceRelay.app` passed
  `codesign --verify --deep --strict`. Existing dormant-agent stripping and
  AppIntents metadata warnings remain. No app was launched.
- `git diff --check` passed. Logs are ignored under
  `var/validation/2026-10-07-regional-voices/`.
- Canvas rendering, actual Settings layout/relaunch persistence, real regional
  speech and listening remain operator checks described in KOKORO_PROVIDER.md.
  No live source reads, uploads, state migration, model/voice downloads or hosting
  changes were performed.

## October 7: per-article delivery and finalizer wait diagnostics

Each completed queue article now requests background delivery immediately, before
later speech finishes. Completion requests survive explicit Stop's transient
progress invalidation; Quit still refuses new work. Ordinary requests during a
drain coalesce into one automatic follow-up, retaining a manual force override if
one arrives, so new publications cannot be stranded until the next periodic tick.
Automatic follow-ups respect the existing local idle check and retry deadlines.
Opt-in diagnostics record finalizer acquisition wait and ready queue counts at
wait start/acquisition using read-only queue records only. Counts exclude running,
failed/paused and preparing entries; read failures report unknown without failing
processing. Disabled logging performs no extra metadata read. No audio policy,
streaming encoding, inference concurrency or dependency changes were made.

Validation after the final source changes:

- **51 core + 17 app-model/source tests passed (68 total)** using the focused
  delivery, single-worker overlap, finalizer diagnostics, encoding policy and
  completion-preservation filters, serially. Existing parameterized fixtures
  separately exercise complete/Stop/Quit and automatic/backoff/forced follow-ups.
- **3 existing app lifecycle tests passed** for explicit Stop, shutdown joining
  owned work and idempotent shutdown/refusal of new work (**71 checks total**).
- A held-speech fixture proves the first article uploads while later speech is
  running. A held feed-confirmation response publishes another article after
  the first drain's media enumeration: repeated requests yield one follow-up,
  confirm new media/feed, preserve force and leave backed-off media untouched.
  Cancellation of a held drain suppresses its queued follow-up on shutdown.
- The controlled finalizer test records one ready item before a blocked wait,
  removes that waiting row and records zero on acquisition, while retaining
  single inference, bounded work, privacy and existing Stop/Quit semantics.
  Missing diagnostic metadata neither creates a database nor blocks processing.
- Signed Xcode **Release build/package passed**, and `dist/VoiceRelay.app` passed
  `codesign --verify --deep --strict`. Existing dormant-agent stripping and
  AppIntents metadata warnings remain. No GUI was launched.
- GUI/Canvas, real inference/listening and live remote throughput remain manual
  operator checks. All transports/providers used here were isolated fixtures;
  no live Safari reads, credentials, hosting or user-state changes occurred.
- `git diff --check` passed. Logs are ignored under
  `var/validation/2026-10-07-publication-overlap/`.

## October 7: idle delivery and duration-aware encoding diagnostics

Delivery drains now repair local deletion intent and detect feed metadata changes
before accessing credentials or WebDAV. Automatic drains with no due media/feed/
deletion work return locally, including during retry backoff; forced Upload Now
and manual Test Connection retain their overrides/probes. Reconciliation repeats
after asynchronous uploads so retirement changes during delivery are preserved.
Successful verified encodes report audio duration, encoding wall time and seconds
of encoding per audio minute using the existing inspection. No additional tool
launch, encoder/bitrate change, normalization or second inference worker is added.

Validation:

- **47 core + 13 app-model/source checks passed** using the focused
  `delivery|Delivery|audioInspectionCache|encodingDiagnostics` filter, serially.
  Includes repeated idle drains with zero credential reads/server requests, stale
  delete rescind, retry deadline/resumption, feed-backoff deletion protection,
  recovered article dates, destination/public URL changes, lost delete intent,
  explicit force, manual connection probes, sanitized opt-in diagnostics and
  no extra audio-tool launches.
- **2 encoding policy tests passed**: 96k defaults/inert legacy loudness metadata
  and preservation of original levels/dynamics, floating-point samples and gaps.
- Signed Xcode **Release build and packaging passed**. The initial restricted
  invocation could not write Xcode package caches; the build succeeded with
  cache/signing-service access. Existing dormant-agent stripping and AppIntents
  metadata warnings remain. No GUI was launched.
- Packaged `dist/VoiceRelay.app` passed `codesign --verify --deep --strict`.
- `git diff --check` passed. Logs are ignored under
  `var/validation/2026-10-07-idle-delivery/`.
- GUI/Canvas, real inference/listening and live remote delivery remain operator
  checks. No live state, credentials, source entries or hosting were changed.

## October 7: single-worker pipeline optimization

Implemented a bounded active queue pipeline: one inference helper/library lease,
one overlapping chunk validation/checkpoint and one FIFO CPU finalizer, with at
most two articles in flight. Waiting rows remain removable until their speech
turn starts. Explicit Stop finishes a started finalizer and discards interrupted
speech; Quit cancels/joins both stages with recovery checkpoints retained. Generic
engines need no lookahead implementation. Kokoro's pinned splitter/model math,
voice, speed, weights, dependency lock and unnormalized 96k AAC remain unchanged.
The helper retains authenticated voice tensors, prepares one request's CPU G2P
ahead, omits unused timestamps and caps reusable MLX allocator memory at 256 MiB.
Native float-WAV bounds/finite-sample checks and byte-identical PCM assembly avoid
per-chunk audio-tool launches; hash-scoped final AAC inspection reuses one complete
probe/decode across staged/final copies. Troubleshooting debug logging now includes
fixed, sanitized stage timings.

Validation after the final source changes:

- Full isolated Swift package suite: **221 core tests + 79 app-model/source tests
  passed (300 total)**, serial `--no-parallel`; core 167.945 s and app 35.064 s.
  Includes Xcode unique-source-reference regression, FIFO/late admissions,
  failure/manual Retry, competing lease, recovery, 96k levels/dynamics/gaps,
  codec checks, delivery fixtures, and read-only source behavior.
- New controlled tests block encoding while the next article synthesizes, and
  block chunk validation while the next inference runs. They verify one inference,
  one finalizer, at most two started articles, prepared-helper reuse, waiting-row
  removal, Stop's completing finalizer, Quit's retained checkpoints, lease release,
  finite/truncated/padded RIFF handling and AAC cache invalidation on changed bytes.
  Float-WAV validation/assembly issues no audio-tool command; final AAC undergoes
  a full probe and decode with at most three tool launches including encoding.
- Python runtime/adapter suite: **22 tests passed**, CPU/mocked inference only;
  covers lookahead reuse/mismatch/error/thread ownership, voice/manifest changes,
  ordered unchanged float samples/speed/pack and missing/nonfinite audio. No model
  was loaded, downloaded or used for real inference by these tests.
- Signed universal Xcode **Release build/package passed** via
  `bash scripts/build-app.sh release`. Final `dist/VoiceRelay.app` passes
  `codesign --verify --deep --strict --verbose=2` using macOS trust services.
  No app was launched. Build warnings are the existing signed dormant agent not
  being stripped and absent AppIntents metadata; no compilation errors.
- The first broad run exposed a Foundation `waitUntilExit()` hang during the
  numeric-speed executable-helper fixture's teardown after its child had exited.
  The isolated stack was sampled; task-owned runners were stopped. Helper/tool
  teardown now awaits termination state/notifications without that thread-local
  run-loop wait. All 14 targeted helper/tool/pipeline checks and the subsequent
  full suite passed. Helper deadlines/cancellation still stop owned descendants
  and clean only owned session scratch after worker exit.
- `git diff --check` passed.

Release (-O) isolated synthetic 75-second mono 24 kHz float-WAV kernel comparison,
one warmup + five measured trials: native validation/PCM assembly median **7.85 ms**
(range 7.52–8.33), versus FFmpeg probe + full decode + float conversion **101.28 ms**
(range 100.98–102.23), about 12.9x less time for this stage. PCM bytes match exactly.
The comparison compiles the actual FloatWave/ToolRunner sources with only metadata
and error-type definitions stubbed; FFmpeg uses the new faster subprocess wait,
making this a conservative tool-path comparison. It excludes model inference,
AAC/RSS/publication/delivery and is **not an end-to-end Kokoro speedup claim**.

Evidence is ignored/project-local under `var/validation/2026-10-07-single-worker/`:
`swift-tests-final.log`, `python-tests.log`, `helper-tests.log`,
`release-build-final.log`, `signature-final.log`, `float-wave-benchmark.json`,
`FloatWaveBenchmark.swift`, and the initial teardown `test-sample.txt`.
No live Safari reads, GUI/Canvas automation, real Kokoro inference, listening,
service enrollment, state migration/reset or remote uploads were performed.
Two inference workers remain deferred. Operator steps are in
[KOKORO_PROVIDER.md](KOKORO_PROVIDER.md#single-worker-pipeline).



Updated October 7, 2026. The deliverable is now `/path/to/VoiceRelay`.
Build/test evidence from before relocation is retained below as historical evidence;
it does not establish a successful build of the new Xcode project. No deferred
production functionality is certified.

## October 7 original-level audio and 96k AAC

The operator identified harshness in the normalized comparison and selected the
96k direct AAC encode after listening to the same isolated Heart/1.0 benchmark
passage at original levels. This is operator listening feedback, separate from
the mechanical app checks below.

AudioProcessor now concatenates float32 PCM with correctly sized existing gaps
and encodes AAC-LC without a loudness filter, gain, limiter or DRC. Mono 24 kHz
M4A defaults to a 96 kbps target. Historical loudness fields remain inert for
saved-profile/import compatibility; explicit diagnostic bitrate/sample-rate
imports remain supported. Unfinished managed episodes adopt 96k while keeping
their captured voice/speed and destination. The encoding policy has its own
fingerprint version: authentic older normalized encoded scratch is rejected,
including a legacy 96k checkpoint, while compatible speech chunks are reused.
Published files remain unchanged. An integrity-confirmed already-placed file
can finish an interrupted publication without being replaced by a policy change.

All 9 focused core tests passed in 76 seconds with --no-parallel, including
four policy-upgrade combinations (legacy 64k/96k, encoded/placed), all five
interruption boundaries, level/range preservation, float precision, gap timing,
defaults, legacy config preservation, multiple artifacts, compatible checkpoints
and captured speech settings. The amplitude test verifies both original RMS
levels and a 20 dB quiet/loud difference within 0.5 dB after AAC decoding.
The Xcode Debug build, strict deep code-signature verification and whitespace
check passed. These checks use synthetic
tones and isolated metadata; they are pipeline evidence, not new Kokoro speech
or listening acceptance. No live data, preferences, queue or remote files were
edited by the checks. Logs are ignored under
var/validation/2026-10-07-unprocessed-aac96/.

Operator check: build/run the updated app, let a newly queued article complete
(or explicitly Retry an existing failed item), and listen to its saved file and
Overcast episode. Keep playback speed and optional player processing consistent
for the comparison. Earlier saved files retain their existing encoding and sound;
regeneration is explicit, not automatic. Existing finalized files are never
re-encoded as a side effect of launch. GUI and live podcast acceptance remain
manual.

## October 7 Queue origin and separator-only speech failures

A read-only inspection of six currently failed native queue items across four
publisher hosts found separator-only first unfinished chunks: hyphens, bullet
or vertical bar. The source paragraph itself had no words/numbers. The installed
Misaki 0.9.4 G2P returned zero phonemes for synthetic --, bullet and vertical-bar
inputs; normal words and 42 produced phonemes. That check blocked networking and
downloads, used the project-local runtime, and did not load the speech model.
The pinned Kokoro pipeline skips segments without phonemes, explaining the
helper's empty_audio result. This diagnosis does not imply a publisher-specific
fetch or authentication problem. No article content/private URLs were logged,
and no live queue, snapshot or audio record was edited.

Queue and Preparing rows now show the original source host, matching Articles.
New SpeechQueueItem records capture it; legacy rows recover it read-only from
the retained inventory or integrity-checked saved extraction. No page fetch is
needed. Narration omits standalone decorative separators, retaining semantic
source blocks, meaningful words/numbers/symbols, article boundaries and footnotes.
Unfinished plans upgrade on Retry; totals use the new plan. Identical chunk
requests retain the prior version's compatible fingerprints, subject to existing
audio integrity and provenance checks. Shifted or changed requests and changed
engines invalidate normally. Existing published audio remains untouched.

All 19 focused core tests and 2 focused app tests passed with --no-parallel
(54 and 5 seconds), including separator omission without source mutation,
meaningful symbols, legacy origin recovery without database writes, an older
separator plan retaining its completed chunk, voice/backend fingerprint changes,
interrupted checkpoint recovery, legacy narration totals, failure/retry behavior,
Reading List queue admission and preview URL resolution. The offline G2P check,
Xcode Debug build, strict deep codesign verification and whitespace check passed.
Logs are ignored under var/validation/2026-10-07-queue-origin-separators/.
The full suite was not repeated. Pipeline tests used synthetic tones; production
speech/listening, GUI and Canvas rendering remain manual.

Operator check: run the updated app, open Queue and verify origin hosts below
titles. Click Retry on an affected item, then Generate Speech if it does not start
automatically. It should finish and leave Queue without the no-audio error.
Listen near article breaks to confirm meaningful text remains intact. Failed
items remain explicit Retry; development checks did not retry them automatically.

## October 7 podcast episode saved dates

Local and remote RSS pubDate and item ordering now use the Reading List saved
date when available; otherwise they use the existing audio publication time.
Episode.readingListSavedAt is optional and backward compatible. publicationDate
remains the independent audio generation/commit timestamp. Enqueue captures the
selected entry's date. Older records resolve it read-only from the retained
catalog by original source key, including articles with different canonical
links. Neither read-only lookup nor RSS rendering rewrites episode records.
Feed metadata changes are detected by candidate RSS hash in delivery summary
and drain, allowing a feed-only update of previously confirmed audio.

All 23 focused core regression tests passed with --no-parallel (88 seconds),
covering saved-date propagation and chronological ordering in both feeds,
generation-time fallback/old JSON, existing-episode date recovery without a
metadata write or audio upload, read-only SQLite, retained source inventory,
queue admission, delivery retry/backoff, failed-feed deletion gates, publication
receipts, destination changes and episode artwork. Two initial date tests also
passed before the final regression run. The Xcode Debug build, strict deep
codesign verification and whitespace check passed. Logs are ignored under
var/validation/2026-10-07-episode-dates/. The full package suite was not repeated.

Live Safari, uploads and Overcast display remain manual. Run the updated app
with publishing enabled, let normal delivery finish (or use Delivery's Upload
Now), then refresh the subscription in Overcast and compare episode dates with
Articles' saved dates. Existing audio and GUIDs are preserved; no regeneration
is needed. Older local RSS is rewritten at the next ordinary pipeline/feed
operation. Validation used only isolated fixtures and fake delivery transport;
no live state or server data was changed.

## October 7 Articles newest-first ordering

Articles now displays entries by saved date descending. Equal dates retain
discovery order, and undated entries appear last in stable order. A newly
discovered dated entry appears in its chronological position without changing
the durable catalog or existing queue. Manual multi-selection enqueues in the
same order shown in Articles. The source-local Articles preview uses synthetic
dates and remains inert.

All 14 focused core tests and 3 focused app tests passed with --no-parallel,
including new checks for refresh/reload ordering, corrected dates, retained
absent entries, equal/missing dates and selected-row order. The existing
source-format, read-only, queue-order and startup/interval/refresh tests passed.
The Xcode Debug build, strict deep codesign verification and whitespace check
passed. Logs are ignored under var/validation/2026-10-07-articles-order/.
The full package suite was not repeated. GUI and Canvas rendering remain manual:
launch the updated app, open Articles, and confirm newest saved dates are at the
top; add a Safari Reading List entry and pull down to refresh to check its
position. No live Safari file, queue, audio, feed or server data was changed by
these checks.

## October 7 Saved Audio upload and publication status

Saved Audio rows now show a cloud/status label: Not uploaded, Awaiting upload,
Uploaded awaiting publication, Published or Upload failed. The distinction is
deliberate: a confirmed media PUT does not establish that feed.xml lists it.
Successful feed uploads record included audio hashes and publication identity
(upload/public folder URLs and channel metadata) in the existing private ledger.
Credentials and the publishing switch do not alter that identity. Changed copies
and destinations cannot reuse old confirmation; a pending newer feed does not
erase confirmation for previously listed, unchanged items. Old ledgers infer
membership only when the exact candidate RSS hash matches their confirmed upload.
No live-state migration/reset or network probe is part of status display.

Upload New Items appears only when publishing is enabled and visible, finalized
audio still needs upload or feed confirmation. It disables while delivery or
credential work runs, remains available after failure, forces the existing retry
path, and hides after all shown items are published. Remote-delete-only work and
pending audio removals do not show it. Automatic delivery remains active.
Rows and button visibility update from metadata at delivery completion and normal
library checks; they do not require reopening Saved Audio. Cached states also
check audio identity, so a replacement with the same episode ID is not mislabelled.

Source changes: VoiceRelayApp.swift contains the row indicator, conditional
toolbar action, metadata cache and an inert delivery-state preview. Delivery.swift
contains feed receipts and the read-only publication snapshot. Focused app/core
tests cover successful publication, media-first ordering, failed feed upload and
retry, preservation of previously published rows, legacy-ledger inference,
changed destinations/public mappings/audio hashes, publishing disabled, pending
removals, no-op completion and preview safety.

Validation: all 53 focused core tests passed (237 seconds), and all 20 focused
app tests passed (82 seconds), with --no-parallel. The final Xcode Debug build,
strict deep codesign verification and git diff whitespace check passed. The
complete package suite was not repeated. GUI/Canvas rendering, live upload, public website mapping and Overcast
device acceptance remain manual; the badge records the app's confirmed server
delivery and does not continually audit remote files.

Validation logs are ignored under var/validation/2026-10-07-saved-audio-delivery/.
final-tests.log records the final regression results; xcodebuild.log and
codesign.log record build/signature evidence. tests.log contains the initial
8-test smoke run before the cache-identity guard and preview update.
The final focused regression command is:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --cache-path "$PWD/.build/swiftpm-cache" --disable-sandbox \
  --skip-update --no-parallel --filter 'delivery|Delivery|savedAudio|SavedAudio|episodeArtwork'
```

Operator checks:

1. Quit the old app and Run the VoiceRelay scheme in Xcode; open Saved Audio.
   Existing confirmed items should show Published after the automatic check.
2. Generate a new article. With publishing enabled, confirm its pending status
   and Upload New Items when delivery remains outstanding. Automatic delivery
   may complete before you press it; that should hide the button too.
3. If testing the manual path, generate with publishing disabled, then enable
   publishing and use Upload New Items before automatic delivery completes.
   Confirm Published only after the feed update, and the button disappears.
4. If a real delivery fails, confirm the item remains pending/failed and the
   button returns after the drain stops. Correct the issue in Delivery and retry.
   Confirm the audio and item in the server feed; no failure injection is required.

## October 7 Reading List refresh, spoken boundaries and Overcast artwork

The chosen read-only source checks at startup, every five minutes, on Articles
appearance/source selection and through the Articles List's native refreshable
action. That action awaits the coalesced read and catalog reconciliation; a tight
loop awaiting an already-finished reader no longer competes with its main-actor
commit. Articles retains its List when empty, displays synchronization progress,
and Troubleshooting shows the last successful check. The remembered source was
classified as Safari's live Bookmarks.plist by its path; protected contents were
not read. The original live missing-entry report remains operator acceptance.

New narration opens with title and source (Open Graph publisher name, otherwise
source host), retains body/footnote order and ends with its own "End of article."
paragraph. Header/footer chunks have no source-block provenance. Versioning
upgrades unfinished plans and queue counts together; finalized audio is preserved.
Optional sourceName/previewImageURL/artworkURL fields decode older records without
a schema migration. Existing SwiftSoup extracts HTTPS-only Open Graph/Twitter
preview URLs; local and remote RSS escape them into item-level itunes:image.
No secondary image fetch, download, crop, embedding, dependency or live reset was
added. Missing/unsafe art never blocks the article.

Current Overcast is the player target. Its official release notes record episode
artwork since 2025.11.1, shown on podcast screens and during playback, rather than
playlists/widgets. Actual publisher image format, size, availability and Overcast
display remain best-effort device acceptance. See
[Overcast release notes](https://apps.apple.com/us/app/overcast-podcast-app/id888422857),
[RSS episode metadata](https://help.apple.com/itc/podcasts_connect/en.lproj/itcb54353390.html)
and [Open Graph metadata](https://ogp.me/). Existing AAC-LC enclosures and private
feed itunes:block handling remain; no Overcast ping/crawler integration was added.

Validation also localized an empty-library SQLite failure: enabling WAL alone
does not create its sidecars before the initializing connection closes. A read
transaction on the writable initializer now materializes them for later read-only
catalog/queue/library queries. This fixes an isolated failure without claiming it
caused the operator's live missing-entry symptom.

| Area | Evidence |
| --- | --- |
| Source/app | All 75 app tests passed with --no-parallel (169 seconds). After the database fix, all 8 focused source/app tests passed again: startup, injected 300-second timer, awaited gesture action, replaced binary plist, coalescing, source switch, error recovery, cancellation and no-source behavior. Safari fixture bytes remain unchanged. |
| Core | 46 of 47 focused sequential tests passed in final-tests.log; the new legacy-queue test initially omitted its fixture audio folder. After correcting that fixture, it passed in legacy-queue-test.log. Coverage includes narration bounds/provenance/footnotes, metadata fallback and unsafe images, publication/RSS, older-record decoding, queue progress/upgrades, SQLite readers and source handling. All 6 focused SQLite tests passed separately, including empty-library reopen and read-only write refusal. |
| Broad attempt | The initial default concurrent run covered 203 core and 75 app tests but failed on empty SQLite initialization and deadline/startup conditions under load. An earlier focused check also found an old preview-error wording expectation, corrected to current Articles UX. SQLite was fixed; reported deadline/startup/stop cases passed in subsequent sequential app or targeted runs. The full core suite was not repeated after corrections; this is not a full-suite green claim. |
| Build/static | Final Xcode Debug build succeeded; strict deep codesign verification and git diff whitespace check passed. No new project-reference or dependency change in this continuation. |
| Manual boundary | No GUI/Canvas rendering, native pull gesture, protected Safari contents, real speech/listening, live upload or Overcast device behavior was exercised. Synthetic speech is pipeline evidence only. |

Ignored logs under var/validation/2026-10-07-article-refresh/: focused.log,
tests.log (initial broad attempt), app-tests.log, sqlite-isolated.log (reproduction),
store-tests.log, final-tests.log, legacy-queue-test.log, agent-deadline-test.log, xcodebuild-final.log and
codesign.log. Checks used the project-local module/SwiftPM caches,
--disable-sandbox --skip-update, and --no-parallel for sequential checks.
The final focused filter was:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --cache-path "$PWD/.build/swiftpm-cache" --disable-sandbox \
  --skip-update --no-parallel \
  --filter 'SourceReviewTests|narration|Narration|readingList|ReadingList|chosenSource|SourceRead|sourceSwitch|requestDuringActiveRead|autoSync|articlePreviewMetadata|episodeArtwork|pullRefresh|queueBatch|readOnlyNativeStore|reviewedLibraryRejectsEscapedMedia|nativeVersionTwoUpgrade|foreignOrNewerDatabase|ownedToolDeadline|speechHelperDeadline|agentClientRejectsConcurrent'
```

Operator steps:

1. Quit the old app, then Run the VoiceRelay scheme in VoiceRelay.xcodeproj.
   Save a new Safari Reading List article before launch; confirm startup finds
   it. Troubleshooting should show a recent Last checked time or a source error.
   If it fails, verify General's source is live Safari Bookmarks.plist and the
   running signed app has the needed macOS file-access permission.
2. Add another Safari item while VoiceRelay stays running and wait five minutes.
   Add a third item, open Articles, pull downward past the top and release.
   Confirm a source check completes and the entry appears, including with an
   initially empty list. Articles appearance also checks immediately.
3. Process a newly imported article and listen for the title/source header, body,
   any footnotes, and final "End of article." paragraph. Existing finalized
   recordings are not rewritten; use fresh content to test these changes.
4. Choose a new article with Open Graph/Twitter preview art. After normal delivery,
   verify its feed item contains itunes:image, then refresh the subscription in
   current Overcast, download/play the new episode and inspect its podcast/Now
   Playing screen. An article without preview metadata must still complete.
   Publisher images may be unavailable or nonsquare.

## October 7 single-folder delivery and subscription URL

Delivery now stores one complete Feed folder URL and one Public folder URL.
Both imply feed.xml and lowercase audio/. Removed WebDAV-root, relative feed,
relative audio and public-media inputs; the full Subscription URL is read-only
with Copy. Public and upload folder addresses remain distinct because the hosting provider
controls the public mapping. No mapping is guessed.

Input uses Foundation URLComponents parsing/encoding and a focused folder policy:
trim whitespace, supply/upgrade HTTPS, normalize host/default ports, repeated
slashes and dot segments, encode spaces/Unicode once, add a directory slash,
ignore anchors, and accept a pasted feed.xml URL as its parent folder. Credentials,
meaningful queries, invalid ports and encoded separators/control characters get
safe field-specific errors. There is no legacy relative-path error for URL input.
WebURL was inspected as a third-party alternative; Foundation already supplies
the parser and serializer this restricted policy needs, so no dependency changed.
See [Apple URLComponents](https://developer.apple.com/documentation/foundation/urlcomponents)
and [WebURL](https://github.com/karwa/swift-url).

URL drafts commit atomically on blur/submit/actions. Invalid edits block explicit
actions against the previous destination; equivalent commits do not cancel a
newly started connection test. Test Connection probes feed/audio read-only,
authenticates against the nearest readable ancestor when feed is missing, and
reports missing folders ready for upload instead of claiming they exist.
Upload probes before parent-first creation, without assuming the host root is
itself a DAV collection. HEAD/DAV size verification remains unchanged.

Old settings decode their feed location into a complete URL, retire independent
audio choices and adopt audio/. Per-copy and ledger destination provenance
re-uploads saved local audio after folder/host changes. Old copies are preserved;
old delete requests do not follow the new destination. A public-folder-only
change updates feed links without uploading unchanged audio. There was no manual
migration, reset, deletion, preference change, Keychain access or live upload.

| Area | Verified evidence |
| --- | --- |
| Focused core | 38 tests passed: URL normalization/idempotence and safe rejection; fixed feed/audio names; encode-once requests; read-only exact DAV confirmation and missing-folder readiness; parent-first creation and 405 races; legacy settings decoding; folder/host changes and preservation of old copies/deletes; public-only remapping; existing authentication, metadata verification, RSS and retirement fixtures. |
| App suite | All 73 app tests passed, including atomic draft normalization, full derived subscription URL, equivalent commit preserving an in-flight test, missing-audio readiness, persistence and inert Delivery controls. |
| Build/static | Xcode Debug build succeeded, strict deep codesign verification passed, git diff whitespace check passed. No project reference or dependency changes in this continuation. |
| Manual boundary | No GUI/Canvas, clipboard interaction, protected-file access, Touch ID/Watch, live DAV upload or public website acceptance was exercised. Full core suite was not repeated. |

Logs: ignored `var/validation/2026-10-07-delivery-folder/` contains final
`tests.log`, `xcodebuild.log` and `codesign.log`. Use the signed Xcode Debug app
for operator testing; a SwiftPM executable does not certify protected Keychain
entitlements.

Operator steps:

1. Quit the old app, then Run the VoiceRelay scheme from VoiceRelay.xcodeproj.
2. In Delivery enter Feed folder URL `https://webdav.example/podcast`.
   Confirm editing accepts the same value with whitespace or without HTTPS and
   settles on `https://webdav.example/podcast/` after leaving the field.
   Save the known app password for this host if it was stored for the old host.
3. Set Public folder URL to the actual website URL serving those same files.
   Verify the provider's published root: if it is the podcast folder, use the
   website root; otherwise include the podcast path in the public URL.
   The upload host is not necessarily the public subscription host.
   Test Connection does not certify public mapping.
4. Test Connection: expect Folders verified, or Connected; folders created on
   upload. Enable publishing and press Upload Now; confirm feed.xml directly
   inside podcast and audio/*.m4a below it. Saved local audio is re-uploaded into
   the new layout without regeneration. Enable Troubleshooting debug logging if
   diagnosing a failure; expect a matched HEAD or PROPFIND size event per upload.
5. Copy Subscription URL, paste it into a browser, confirm current feed items
   and reachable audio links, then paste it into the podcatcher. Verify neither
   copy nor RSS adds a second feed.xml or audio directory.

## October 7 uploaded-size verification and public website investigation

The operator's sanitized log confirms successful folder creation/probes,
PUT 201/204 and HEAD 200 followed by the former generic verification error.
This localizes the failure to size comparison, but the old log does not show
whether the HEAD Content-Length was missing, invalid or mismatched. No live
authenticated HEAD/PROPFIND or Keychain operation was performed by the agent.

Uploaded files still require an exact reported byte length. HEAD requests now
prefer identity encoding and bypass cache; matching lengths remain the fast
path. Missing/invalid/mismatched lengths or unsupported HEAD (405/501) trigger
a read-only Depth-0 PROPFIND for DAV:getcontentlength and resourcetype on the
exact file. The fallback accepts only a successful, namespace-correct,
unambiguous noncollection file property with a nonnegative decimal Int64 size.
Wrong resources/origins, failed properties, malformed/entity-declaring XML,
duplicate lengths/responses and collection results are refused. The XML body or
its HTTP Content-Length is never treated as the file's length. Authentication,
permission, redirect, transport and cancellation failures are preserved.

Fixed debug events show HEAD/PROPFIND matched, unavailable, mismatch or
unsupported, with no raw headers, byte counts, endpoints or content. Explicit
Upload Now also retries already-saved remote-size verification failures; other
fatal failures remain manual. Failed media stay out of RSS, and failed feed
verification keeps remote deletes gated until a confirmed replacement.

Protocol basis: HTTP permits omission of generated HEAD metadata in
[RFC 9110 section 9.3.2](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.3.2).
[RFC 4918 section 15.4](https://www.rfc-editor.org/rfc/rfc4918.html#section-15.4)
defines DAV:getcontentlength as the representation length. No provider-specific
HEAD behavior is asserted without live response metadata.

The user explicitly requested verification of public URLs/stale content.
Read-only inspection found uploads directed to a different folder from the
public website's published root, plus a public hostname that failed TLS
hostname validation. A provider-supported public address passed TLS and returned
stale feed content. Private addresses and response bodies are omitted from this
record. Public paths can differ from WebDAV's account/files ancestors; verify
the hosting provider's published root and do not guess the mapping or silently
change preferences, hosting or subscription URLs. Test Connection certifies
only readable WebDAV folders, not the public website.

| Area | Evidence and limits |
| --- | --- |
| Core fixtures | All 36 delivery tests passed, including cases for missing/malformed/mismatched/unsupported HEAD, matching DAV size for feed and file uploads, encoding headers, strict metadata rejection, cancellation/auth/redirect preservation, saved verification-failure retry, public-vs-DAV path independence and feed-size failure blocking deletes. The parameterized feed-failure test covers PUT failure and metadata failure. |
| App suite | All 71 app tests passed. Source-local inert delivery controls still construct. |
| Build/static | Xcode Debug build succeeded; strict codesign verification and diff whitespace checks passed. Project references were unchanged. |
| Live boundary | Only user-authorized unauthenticated public GETs and nonsecret preference reads were run. No app GUI, credentials, authenticated DAV calls, uploads, hosting changes, local-state writes or subscriber updates. Actual provider getcontentlength compatibility and matching public root remain operator acceptance. |

Logs: `var/validation/2026-10-07-webdav-size/` (gitignored).

Operator sequence: Quit the old app and rebuild/run VoiceRelay → My Mac. Keep
Publishing disabled while confirming the provider's published website root.
Align upload/public folders and use a provider-supported public HTTPS URL.
Enable debug logging, re-enable
Publishing and use Upload Now to recover prior size-verification failures. A
successful run should show HEAD matched or HEAD unavailable/mismatch followed
by PROPFIND matched. Verify the corrected public feed contains current entries
and correct enclosure URLs, and verify subscriber access separately. Copy the
log before Quit if verification still fails. No password resave is needed for
path-only changes on the same WebDAV host/username.

## October 7 WebDAV paths and existing-folder handling

The operator's evidence showed MKCOL returning 403 while a root PROPFIND returned
207, plus validation rejecting nested folder paths. The supplied GET directory
listing established an existing capitalized `Podcast Feed/` folder; it does not
establish write access or the location/existence of an audio folder. The provider
supports both an account/files path beneath its DAV root and a direct files root.
No private account names/endpoints from the attachment were copied into source,
fixtures or this record.

Feed folder receives feed.xml; Audio folder receives .m4a files. Both fields are
now independent relative paths beneath the WebDAV root URL, with blank meaning
root. Nested paths, spaces, Unicode and percent-encoded spaces work. Validation
rejects absolute paths, empty segments, traversal, control characters and
encoded separators/double escapes. URL components are appended separately;
collection requests use canonical trailing slashes without accepting redirects.
Older persisted media-subfolder settings decode to the same remote destination,
and new round-trips retain independent paths. No uploaded file is relocated.

Test Connection checks the root and both configured destinations read-only,
deduplicating shared paths; it reports missing folders and never creates them.
Uploads probe every ancestor first, create only 404-missing collections in
parent order, and verify created collections or 405 creation races. Existing
readable folders never receive MKCOL, including existing account/files
ancestors. A denied/noncollection response stops creation. Debug logs identify
root/feed/audio role and depth using typed events without recording names/URLs.
The UI labels are WebDAV root URL, Feed folder and Audio folder; the success
indicator is Folders verified. An empty-result drain with a stored error now
reports Delivery needs attention rather than Delivery up to date.

| Area | Evidence and limits |
| --- | --- |
| Delivery core | All 33 delivery tests passed. New fixtures exercise independent nested destinations, once-only space encoding, root confinement/auth headers, old-settings destination preservation, existing-folder MKCOL 403 avoidance with successful PUT/HEAD, ordered missing-parent creation, read-only missing-folder reporting, 405 verification and denied-probe refusal. Existing feed-before-delete, confirmed-byte upload, retry/privacy/session tests remain green. |
| App suite | All 71 app tests passed. Delivery checks now expect root/feed/audio probes. New coverage reproduces a collection failure with zero pending media and confirms the corrected status plus recovery. |
| Build/static | Xcode Debug build succeeded; strict signature verification and diff whitespace check passed. Existing signed-agent stripping/AppIntents metadata warnings remain. No project-file change in this continuation; its reference regression was already passed in the preceding Keychain update. |
| Acceptance limits | No GUI/Canvas run, live Keychain operation, live DAV request/upload, Safari access or live-state change. The real server's response to PUT/MKCOL/HEAD and its public feed/audio mapping remain manual validation. No full core-suite rerun; historical caveats remain. |

Logs: `var/validation/2026-10-07-webdav-paths/` (gitignored).

Operator sequence: Quit the old app and build/run VoiceRelay → My Mac in Xcode.
Keep Publishing disabled and enable debug logging while editing. Use the Files
directory URL as WebDAV root, Feed folder `Podcast Feed`, and Audio folder
`Podcast Feed/Media` if that is where audio belongs. Alternatively, use the full
existing Podcast Feed directory URL as root, blank Feed folder and `Media` Audio
folder. Preserve server casing and do not duplicate account/files prefixes when
the root URL already contains them. Test Connection should verify all existing
destinations; a missing audio directory is reported without writing anything.
Enable Publishing and use Upload Now for the intended creation/upload test;
existing ancestors should show PROPFIND without MKCOL, and PUT/HEAD confirm the
uploaded byte count. Public URLs must separately map to those feed/audio paths.
Copy Debug Log before Quit if anything fails, then disable logging.

## October 7 protected Keychain and shared credential session

The operator authorized changing credential security policy and dispensing with
legacy credential compatibility during development. The app now uses only the
device-local Data Protection Keychain, with `whenUnlockedThisDeviceOnly` and
biometry, Mac password or supported companion authentication combined with OR.
The former login-Keychain item is never queried or migrated. Re-save the known
WebDAV password once in the new store. One LAContext is shared across native
credential operations; successful passwords are retained in memory until Quit.
This implements session reuse, not a guarantee about every macOS confirmation:
credential replacement/removal or different accounts may still need approval.

All tests and delivery drains share a serialized credential store, including
concurrent requests. Settings presence is cache-only and does not authenticate.
Cancelled/denied reads are cached so automatic work cannot open a prompt loop;
explicit Test Connection or Upload Now permits retry. Save caches the supplied
password without a follow-up read. Keychain operations run off the main UI
thread; Quit invalidates pending authentication, awaits owned operations, then
releases session credentials. Debug events distinguish actual credential reads
from cached reuse without recording sensitive values.

The app target now has application-identifier and Keychain access-group
entitlements. Xcode embedded its existing matching Mac development profile.
The optional packaging script uses Xcode and copies its signed bundle intact,
preserving entitlements/profile instead of constructing a SwiftPM bundle.

| Area | Evidence and limits |
| --- | --- |
| Focused fixtures | 30 core delivery tests plus the Xcode source-reference regression passed; all 10 app delivery tests passed. New coverage includes 24 concurrent reads coalesced into one query, cache-only presence, explicit denial retry, save/delete invalidation, session reset, fresh-store query attributes and in-memory access-control creation. App fixtures exercise repeated connection tests, uploads and relaunch with one read per session. |
| App suite | All 70 app tests passed. Synthetic audio remains pipeline evidence only. |
| Build/signing | Xcode Debug build succeeded; strict codesign verification passed. Signature inspection confirms the expected application identifier and Keychain group. Existing dormant-agent strip/AppIntents metadata warnings remain. |
| Static/packaging | Entitlements/project plist lint, script syntax and diff whitespace checks passed. An isolated Bash 3.2 fixture exercised default Debug packaging, Release identity override and generated-bundle replacement with stub build/signing commands. Full packaging route was not run. |
| Scope | No real Keychain read/write/delete, GUI/Canvas run, Touch ID/Watch/password authentication, live DAV request/upload or state migration. Actual prompt count and hardware authentication remain operator acceptance. No full core-suite rerun; prior core-suite caveats remain. |

The initial policy-construction fixture rejected combining `userPresence` with
`companion`; an isolated in-memory check established the valid explicit
`biometryAny | devicePasscode | companion | or` combination, now covered by the
passing fixture. The new app fixture was corrected to initialize its library
before changing delivery settings. Final logs are under
`var/validation/2026-10-07-keychain-session/` (gitignored).

Operator sequence:

1. Disable Publishing in the old app, Quit it, then build/run VoiceRelay → My
   Mac from Xcode. Enable debug logging in Troubleshooting.
2. In Delivery, save the independently verified WebDAV app password into the
   fresh protected store. Keep Publishing disabled for the initial check.
3. Quit and relaunch. Click Test Connection and complete the authentication
   offered by macOS (Touch ID, supported paired Watch or Mac password).
4. Repeat Test Connection, close/reopen Settings and test an intended upload
   after enabling Publishing. Normal reads should reuse the session without
   another prompt; the log should show cached reuse with no Keychain query.
5. In a new session, cancel the first unlock. Automatic drains should not
   repeatedly prompt; an explicit Test Connection should allow another attempt.
   Copy Debug Log before Quit if behavior differs, then disable logging.

## October 7 delivery authentication and opt-in debug logging

The operator confirmed the WebDAV hosting credentials work independently. This change
addresses the app's credential handling and destination validation without live
credential or server access. Test Connection now issues one read-only
`PROPFIND Depth: 0`, validates a successful DAV collection property for the exact
requested resource, rejects malformed/wrong-resource/non-DAV/entity-declaring XML,
and canonicalizes directory URLs without accepting redirects. It creates no
collections or files and does not certify write permission. An existing-resource
MKCOL 405 must also pass the collection check before uploads proceed.

Credential identity is normalized across UI, persisted settings and Keychain
save/presence/read/delete. A test/drain reads the password once; missing, denied,
cancelled/unavailable Keychain access, HTTP 401 and HTTP 403 have distinct safe
messages. Settings/password changes invalidate in-flight tests. Upload Now
explicitly retries credential/permission-blocked media without changing the
settings hash or retrying unrelated fatal failures. The optional packaging
script now defaults to Apple Development signing, with an explicit identity
override for fixture packaging.

Troubleshooting adds Enable debug logging, Copy Debug Log and Clear Log. The
toggle persists, but only the newest 200 events stay in session memory. Disabling
stops recording; clearing or Quit removes captured events. Fixed event types
prevent logging passwords, usernames, endpoints, paths, headers, article content
or server bodies. Tests inject private-looking values and verify they stay out
of the log. The new named source-local preview is synthetic and inert.

| Area | Evidence and limits |
| --- | --- |
| Focused fixtures | 27 core delivery tests and 9 app delivery tests passed. New coverage includes collection XML/status/resource validation, 405 verification, normalized credential identities, one password read, Keychain errors, 401/403 distinctions, explicit recovery without settings changes, stale test results, logging privacy/bounds/toggle persistence and inert controls. |
| App suite | All 69 app tests passed; project-reference uniqueness regression passed separately in the same invocation. |
| Build/signing | Xcode Debug build succeeded with Apple Development signing. Strict codesign verification succeeded in the normal macOS trust context. The packaging script passed `bash -n`; its full packaging/signing route was not run. |
| Scope | No full core-suite rerun; October 5's known core-suite caveats remain. No GUI/Canvas rendering, real Keychain operation, live DAV request/upload, subscriber fetch or listening acceptance by the agent. No live state reset or migration. |

Logs: `var/validation/2026-10-07-delivery-auth/` (gitignored).

Operator sequence: disable Publishing in the old app and Quit; open the Xcode
project, choose VoiceRelay → My Mac, build/run. Enable debug logging in
Troubleshooting. In Delivery, use the complete upload folder URL supplied by
your WebDAV provider, its required login username and a write-authorized app
password, and Save Password for the new host. Keep Publishing disabled for Test
Connection; expect Authentication verified. Match upload folders to the public
website/feed/audio paths before enabling Publishing and clicking Upload Now.
Check the remote feed/media and subscriber access separately. Copy Debug Log
before Quit if any step fails, then disable logging when finished. Rebuild once
more without resaving the password to check Keychain consent persistence.

## October 5 app-owned automation: delivery wiring, auto-admit, Drain and Stop semantics

Stage 2 wired the delivery core into the running app: a third **Delivery**
Settings pane (endpoint, remote folder, channel name, public feed/audio URLs,
Test Connection with success/failure status), non-secret settings in
UserDefaults with the password held only in Keychain via an injected
`DeliveryCredentialStore` seam, and an injected `DeliveryTransport` seam. While
running, the app auto-drains pending delivery after publication,
retirement/removal, launch and refresh plus a ~60 s periodic tick; auto-admits
newly discovered Reading List entries; auto-processes the ready queue;
re-readies interrupted `.running` items on launch when automation is enabled;
and explicit Stop suspends auto-processing until new work arrives or Generate
is pressed. Saved Audio rows now show duration and file size. Raw logs are
under `var/validation/2026-10-05-delivery-app/`.

| Area | Evidence and limits |
| --- | --- |
| Delivery app wiring | `deliverySettingsPersistWithoutPasswordAndReload` proves the Codable `DeliverySettings` round-trip excludes the password; `deliveryPaneAndAutomationControlsConstructInertly` and `deliveryTestConnectionClassifiesOutcomes` cover inert construction and success/failure classification through the injected seams; `disabledDeliveryIsInertAndShutdownRefusesNewDrains` covers the disabled path and shutdown refusal. `publishMarksDeliveryPendingAndDrainUploadsMediaBeforeFeed` covers publish-marks-pending plus media-before-feed drain order in the app model. No live endpoint or Keychain item was contacted — all transports/credential stores are fakes. |
| Automation | `autoAdmitAddsCurrentEntriesAndSkipsRecordedOrAbsentOnes` covers admission skipping recorded/absent entries; `failedAutoAdmissionStaysRetriedOutForSessionButManualBypasses` covers the no-retry-loop suppression and manual override; `autoProcessDrainsReadyQueueAndStopHaltsUntilNewWorkOrGenerate` and `stopQueueSuspendsAutomationUntilAutoAdmissionArrives` cover the drain and Stop suspension/resumption; `launchRefreshRereadiesInterruptedItemsWhenAutomationEnabled` covers launch recovery of `.running` items. |
| Saved Audio metadata | `savedAudioMetaFormatsDurationAndSize` covers the row duration/byte-size formatting. |
| App suite | Full `VoiceRelayAppTests` run: **66 tests passed** (`app-tests.log`). Two previously load-sensitive mutation tests (`generateAwaitsPendingRemovalAndSynthesizesOnlyRemaining`, `stopDuringMutationAwaitSynthesizesNothingButFinishesMetadata`) were hardened: they now hold the competing writer lock only across the synchronous `runQueue()` call instead of across a 200 ms `MainActor` sleep, removing the wall-clock race against `metadataWriter`'s bounded writer-busy deadline without weakening the asserted ordering. |
| Core suite | Full `VoiceRelayCoreTests` run: 183 tests, **10 issues** (`core-tests.log`). One is the pre-existing `reviewedLibraryRejectsEscapedMediaBeforePresentingSavedFiles` SQLite failure, reproduced identically on the clean baseline commit `8801a13` (not caused by this change). The remainder are parallel-load timing flakes in untouched code — `selectedFetchDeadlineAndCancellation`, `ownedToolDeadlineAndCancellationAreBounded` and `agentClientTimesOutAndRejectsInvalidTimeoutsWithoutConnecting` measured ~20 s against <3 s expectations under the full parallel load; all pass in the isolated rerun (`flake-rerun.log`, **4 tests passed** including `xcodeProjectAppSourcesUseUniqueBuildFileReferences`). |
| Agent checks | `swift test --filter 'agent|Agent'`: **14 tests passed** (`agent-tests.log`); `.build/debug/VoiceRelayAgent --self-check`: passed, no listener or storage started (`agent-selfcheck.log`). |
| Build | Incremental `xcodebuild -scheme VoiceRelay -configuration Debug -disableAutomaticPackageResolution build`: **BUILD SUCCEEDED** (`xcodebuild-final.log`). `git diff --check` clean (`diff-check.log`). `project.pbxproj` was edited (Delivery.swift + DeliveryTests.swift references) and the uniqueness regression passed. |
| Secrets | No password is persisted anywhere: `DeliverySettings` Codable has no password field, the Keychain service is the only store, and delivery errors/tests surface sanitized text without secrets or raw server detail. |
| Operator gates | No GUI/Canvas run, no live endpoint configured, no real Keychain item written, no Overcast/subscriber acceptance. Test Connection was exercised only against fake transports; real WebDAV/TLS behavior, pane rendering, glass selector and actual upload remain manual checks. |

## October 5 UI presentation: refresh removal, automatic source sync, notice dismissal, compact Settings

The user asked to remove visible Refresh controls everywhere, synchronize the
chosen Reading List source automatically (chosen-source-only, ~30 s while the
app runs plus Articles-appearance and chooser triggers), stop Queue
Generate/Reset from greying during row removals, dismiss errors via a
hover-revealed ⓧ without touching stored state, compact the Settings pane
selector to 232×54 with a native keyboard-focus cue instead of a persistent
tinted box, floor all visible text at 12 pt with prose moved behind ⓘ header
controls, and drop the Saved Audio Play button in favor of Show in Finder.

| Area | Evidence and limits |
| --- | --- |
| Refresh removal | `WorkspaceView`'s shared Refresh toolbar item and the Troubleshooting "Refresh Reading List" button are removed; no hidden menu equivalent exists. Internal library mechanisms are untouched: `refreshLibrary()` on appearance/mutations, the 15-minute maintenance loop and the 3-second saved-audio poll. The former manual `SourceReviewModel.refresh(profile:)` API was replaced by `synchronizeOnce`/`requestSourceSync` (recorded here, not reintroduced). Core error strings that told users to "refresh Saved Audio" now say "reopen Saved Audio" (copy-only edits); the automatic recheck itself is unchanged. |
| Automatic source sync | `SourceReviewModel` owns `autoSyncTask`/`immediateSyncTask`, cancelled and awaited in `stop()`. A nil source loads the private catalog only and never touches the default Safari location; the injected `stateRoot`/`snapshotReader` seams keep tests off UserDefaults and the real plist. `autoSyncWithoutChosenSourceNeverReadsPlist`, `chosenSourceSyncsAndRetainsAbsentInventory`, `failedSourceReadPreservesInventoryAndSuccessClearsError` and `stopCancelsAndAwaitsOwnedSourceRead` cover zero-read nil source, chosen-source reconcile with absent-entry retention, failure preserving inventory then success clearing the error, and stop awaiting the owned reader then refusing new reads. Background reads never set `busy` and reconcile writes only on real membership/entry changes. Rework: reads now run in an owned `sourceReadTask` awaited by `stop()` even for direct `synchronizeOnce` calls; `setSource(_:)` bumps a generation token, cancels the in-flight reader and queues an immediate recheck, and generation guards after the reader, after the catalog load and before every commit/UI assignment keep a superseded source from overwriting newer data. `requestSourceSync` now awaits an in-flight read instead of dropping the request, so overlapping requests coalesce into one extra pass rather than being lost for 30 s. `sourceSwitchDuringReadCommitsOnlyNewSource` and `requestDuringActiveReadCoalescesExtraPass` cover both. |
| Stable queue controls | `canGenerateAudio`/`canResetQueue` no longer gate on `queueMutationBusy`; `runQueue` drains the FIFO mutation executor before the queue snapshot, and `resetQueue` enqueues behind pending work under `isQueueResetPending`. `queueControlsStayEnabledDuringRowMutation` (held writer, controls stay true while two rows remain), `generateAwaitsPendingRemovalAndSynthesizesOnlyRemaining` (recording backend proves only the surviving article synthesizes), `confirmedResetBehindPendingRemovalClearsAllRows` and `stopDuringMutationAwaitSynthesizesNothingButFinishesMetadata` cover the ordering. |
| Notice dismissal | `NoticeDismissalState` keys suppression per `(context key, exact message)` — global, audio, source, enqueue, and queue-row `id:attempts:state` keys. `noticeDismissalIsKeyedStableAndPresentationOnly` verifies repeats stay hidden, a new attempt/message re-shows, reset restores, and the `SpeechQueueItem` is untouched; `previewErrorClearKeepsReviewContentAndStoreUntouched` covers the preview path. The hover/focus-revealed ⓧ is keyboard accessible; hover reveal itself is an operator GUI check. |
| Compact Settings | Selector constants are 232×54 with 20 pt symbols and 12 pt labels; the glass selected tile is preserved and `focusEffectDisabled` + a rounded keyboard-only `.tint` focus cue (marked only while the current event is a keyDown; mouse activation clears it) replace any persistent focus box. `settingsPanesShareFixedGlassControlLayout` (updated constants) and `typographyAndSelectorConstantsMeetPresentationFloor` cover the values; the actual Tab/Space focus cue and mouse-clearing behavior need operator verification — source inspection cannot prove OS focus rendering. `AppTypography` floors app text at 12 pt; `subheadline`/`caption` usages in active UI were replaced and section footnote prose moved into `SectionHelpHeader` ⓘ popovers. |
| Saved Audio | The Play button and `openAudio(_:)` are removed; rows keep Show in Finder. Docs direct listening to Finder + Quick Look. |
| Tests | Focused raw run (`var/validation/2026-10-05-ui-presentation/focused-tests.log`, argv and exit code captured): **1 core + 27 app = 28 tests passed, 0 issues** — 11 new cases plus touched regressions (queue reset/generation availability, row-removal state, selection threshold, captured reset IDs, shutdown, preview, troubleshooting/settings construction). Rework raw run (`rework-tests.log`): **10 tests passed, 0 issues** — new `sourceSwitchDuringReadCommitsOnlyNewSource`, `requestDuringActiveReadCoalescesExtraPass` and `explicitOperationsResetDismissedNotices` plus the nil-source/success-failure/stop-owned and typography/settings/notice cases. No full suite, agent tests, GUI, network, model or live data ran. |
| Build | One incremental `xcodebuild -project VoiceRelay.xcodeproj -scheme VoiceRelay -configuration Debug -disableAutomaticPackageResolution build` on existing DerivedData: **BUILD SUCCEEDED** (`xcodebuild-increment.log` pre-rework, `xcodebuild-rework.log` post-rework); warnings are the pre-existing signed-binary strip note and AppIntents metadata skip. `git diff --check` clean; zero net comment-line delta vs the pre-increment baseline. |
| Operator gates | Hover-reveal visuals, glass/focus-cue rendering, 12 pt readability in context, automatic sync on a real chosen plist, and any Canvas preview remain manual checks; nothing here proves OS redraw, focus or hover behavior. |

## October 5 SQLite concurrency, shared removal controls and Saved Audio deletion

The user reported "Native SQLite write failed." when adding many articles and
processing immediately, plus control flicker on queue row removal. An isolated
diagnostic reproduced the mechanism: on Apple SQLite 3.54 under rollback
journaling, a held same-process read-only transaction fails a native write with
`SQLITE_IOERR` 10, extended `SQLITE_IOERR_LOCK` 3850 (errno EBADF) — not the
hypothesized `SQLITE_BUSY` — recorded in `sqlite-green.log`/`red-diagnostic.log`
under `var/validation/2026-10-05-library-controls/`. The live incident's extended
code was never captured, so this is a reproduced mechanism, not proven live
causality. The fix was authored separately and frozen: `busy_timeout` 2000 ms on
read and write connections, `PRAGMA journal_mode=WAL` after native ID/version
validation, `SQLITE_FCNTL_PERSIST_WAL=1`, with FULL synchronous, foreign keys
and the writer flock unchanged. WAL plus persisted sidecars was verified by an
independent 16-case probe; this increment does not change journaling, timeouts
or ordering. Errors now report numeric SQLite extended/system codes with
role-only messages — no SQL text, errstr, paths or content.

| Area | Evidence and limits |
| --- | --- |
| Concurrency | `sqliteCommitWaitsForConcurrentReader` was red before WAL (commit failed in 0.06 s under a held shared read lock) and green after; `readOnlyNativeStoreReadsAfterLastWriterClosed`, `readOnlyNativeStoreRefusesWrites`, `nativeVersionTwoUpgradePreservesWAL` and `foreignOrNewerDatabaseIsRefusedWithoutWALSidecar` cover persisted-WAL reopen, read-only write refusal, v2→v3 upgrade and foreign/newer refusal without sidecars. `sqliteCommitProbeReportsBusyCode` keeps the DELETE-journal mechanism probe on an isolated database, recording the actual `rc=10 extended=3850`. |
| Diagnostics | `sqliteFailure(operation:)` emits `Native SQLite <role> failed (SQLite <code>, system <errno>). Saved progress is retained.` and a busy/locked variant; `sqliteFailureReportsCodesWithoutContent` asserts numeric codes with no SQL or path leakage. |
| Removal controls | Queue and Saved Audio share `SelectionManagementControl` (reset below two selections, Remove Selections at two or more, one stable button) and `RowRemovalButton`; `selectionManagementControlSwitchesToBulkAboveOneSelection` covers the threshold and both panes' construction. |
| Flash fix | Queue mutations now run on a single model-owned FIFO executor with per-entry `mutatingQueueEntries` state and never touch `running`/`processingSpeech`/progress; `queueRowRemovalLeavesSpeechStateAndProgressUntouched` and `rapidQueueRemovalsBothComplete` cover state preservation and FIFO completion. Whether the visible flicker is gone needs operator GUI confirmation — tests prove state stability, not redraw. |
| Queue preview | `articlePreviewURL(articleID:stateRoot:)` resolves the preview from the integrity-checked snapshot via a validated read-only store; `articlePreviewURLResolvesSavedSnapshot` (including a nil `sourceEntryID` item) and `articlePreviewURLRefusesMissingCorruptOrForeignState` cover success and refusal; `queuePreviewResolvesSavedSnapshotURL` covers the app seam. The resolver performs no fetch; the opened preview window fetches the page as it does for Articles rows. |
| Saved Audio removal | `removeSavedAudio(ids:storage:)` validates the whole target group, commits `expired`+manual intent and pending feed atomically, writes the local feed before unlinking, rechecks hash/size/inode immediately before `removeItem`, then clears intent; `resumePendingAudioRemovals(storage:)` finishes durable intent after crashes/failures. Core tests cover single/bulk deletion, captured-ID reset, feed-failure durability with resolver retry, unlink-failure visibility and retry, confirmed-missing idempotency, unavailable/substituted refusal, competing-lease and foreign-library refusal, and `.never` not resurrecting flagged intent. App tests cover model deletion/pruning and the processing block. |
| Rework pass | Review hardening, same increment: regeneration refuses while manual intent is pending (`resumeRefusesUntilPendingRemovalResolves`), the resolver refuses invalid flagged records before any mutation (`pendingRemovalResolverRefusesNonExpiredFlaggedRecord`), an empty removal request is a no-op that creates nothing (`removeSavedAudioEmptySelectionIsNoop`), the pre-unlink identity recheck now includes size/mtime/ctime and refused an in-place edit through the `beforeOwnedAudioUnlink` seam (`removeSavedAudioRefusesInPlaceEditBeforeUnlink`), binding failures report their result code before statement finalization (`sqliteErrorReportsBindingFailureCode`), Saved Audio reset captures displayed IDs separately from the dialog binding (`savedAudioResetCapturesDisplayedIDsNotLiveList`), the preview task guards ownership by request ID so a cancelled resolver cannot clear its successor, and reconcile/expire share the feed-write helper. Final refinements: `removeSavedAudio`/`resumePendingAudioRemovals` re-validate the library and re-derive targets/flags from a fresh read **under** the `PipelineLease` (`pendingRemovalResolverReReadsUnderLease` proves a probe-to-lease mutation is re-read and left untouched; `removeSavedAudioDerivesFromFreshLeasedSnapshot` proves removal uses the current record), and a cancelled stale preview resolver can no longer assign `model.error` for a newer request. Narrow rerun: **23 core + 5 app = 28 tests passed** (summarized in `rework-summary.log`); final raw narrow run of the touched cases: **9 tests, 0 issues** (`rework-final-tests.log`); incremental Xcode Debug **BUILD SUCCEEDED** (`xcodebuild-final.log`). The earlier 56-test focused gate result stands for the pre-rework state. |
| Limits | Focused filters only; no full suite, GUI, network, model or live data ran. Deletion used disposable fixture files only. |

## October 5 queue lifecycle: live drain, explicit Stop and decorative-quote narration

The user directed a queue lifecycle rework: one transport slot (Generate Speech
idle / Stop during owned speech), Ready checkmarks, Add to Queue working during
speech, a drain that processes Ready plus pending and late-arriving work,
per-article failure continuation, atomic multi-row removal, and an explicit Stop
that abandons only the interrupted item's owned scratch and checkpoints and
returns its row to Ready — while error/Quit retention stays distinct. Frozen
evidence also showed a standalone decorative quotation mark (U+275D) producing
zero upstream speech segments; narration now omits the strict quote-only set and
the plan version was bumped (`decorative-quotes-1`) so older unfinished
narration regenerates a compatible plan before continuing.

| Area | Evidence and limits |
| --- | --- |
| Worker split and lease | `FixtureCoordinator.execute` is a nonisolated static using `PipelineStore` (short-lived stores per step, bounded writer-busy retry) plus `PipelineLease` (`flock` on `*.speech.lock`, owned-fd, `O_NOFOLLOW`, euid/regular-file checks). `enqueueCommitsWhileSpeechWorkerIsBlocked` proves an enqueue commits while the synthetic TTS gate is held; `pipelineLeaseBlocksCompetingWorkerAndReleasesDeterministically` and `queueDrainRefusesSecondDrainAndParallelWorkerLease` cover cross-coordinator and same-coordinator exclusion. |
| Drain | `drainQueue` takes the earliest Ready row, waits out pending preparations (50 ms cancellable sleep, re-reads once after the count reaches zero) and continues after per-item failures. Covered by `queueDrainWaitsForPendingPreparationsAndProcessesLateCommits`, `queueDrainWithOnlyPendingWorkProcessesCommittedArticle`, `queueDrainContinuesAfterArticleFailureAndReportsFailedItems` and app-side `drainCommitsPendingAddsWhileSpeechIsBlocked`. Legacy `runQueuedBatch` keeps fixed-batch semantics for fixture/CLI callers. |
| Stop vs cancel | `queueStopAbandonsInterruptedWorkAndRestoresReadyRow`: completed media/feed unchanged, current row returns `.queued` with owned work child gone and chunks cleared, snapshot/inventory/preferences/siblings preserved, rerun regenerates fresh work. `abandonedWorkPreservesPublishedMediaAndRejectsUnsafeRoots` covers published-media preservation and symlink refusal; `abandonInterruptedWorkPreservesStagedPublicationBoundary` separately covers `.audioPlaced`. `stopAbandonsActiveWorkRestoresReadyAndReturnsGenerate` covers the app-level transport. Quit/legacy cancel still retain paused checkpoints (existing tests unchanged). |
| Completion order | `queueCancellationBeforeSuccessAcknowledgementRetainsItem` was updated for the settled semantics: a cancel arriving at `.published` (after the feed commit) still completes and dequeues — previously it retained the row paused. The `.encoding` arm keeps paused retention. |
| Admission and removal | `repeatedAddsWhilePendingKeepEveryEntryInOrder`, `removingPendingAddBeforeCommitAndReaddingUsesFreshToken`, `queueBulkRemovalIsAtomicAndPreservesSourceAndMedia` and `selectionRemovalCoversReadyFailedAndPreparingRowsWithoutDialogs` cover tokenized admission, atomic membership removal and no-confirmation X/Remove semantics (pane resets confirm). |
| Decorative quotes | `narrationOmitsStandaloneDecorativeQuotesWithoutDroppingContent` failed red (4 issues) on the old plan, then passed on the `decorative-quotes-1` implementation along with `narrationHasBoundsUnicodeAndLosslessLongTokenFallback` and `semanticBlocksKeepNestedOrderAndSpecialStructures` (`ornament-before.log`/`ornament-after.log` in `var/validation/2026-10-05-queue-drain/`). Frozen metadata only — no article body, UUIDs or source URLs in the record. |
| Tests | New-behavior filters (`core-new-tests.log`: 9/9 core; `app-new-tests.log`: 5/5 app) pass. The combined focused gates did **not** pass as runs: `focused-gate-3.log` reports 102 tests with 6 core issues and `focused-gate-clean.log` 126 tests with 9 core issues; the app suite stayed green (30/30 in that run, 25/25 previously). The core issues were sub-5-second wall-clock deadline failures in `ownedTool…`, `speechHelperDeadline…`, `selectedFetchDeadline…` and agent-client tests, plus one speech-helper cancellation case that surfaced the wrong error type in the broad run. The same tests pass in isolation (`failures-rerun.log`) — the load-contention hypothesis is plausible but **not proven**; no bound was weakened. |
| Build | One incremental `xcodebuild` Debug `VoiceRelay`, existing DerivedData/caches, automatic package resolution disabled (`xcodebuild-queue.log`): result recorded in that log. GUI rendering, real Kokoro inference, listening and live Reading List access remain operator gates. |
| Limits | Focused-scope evidence, not a full suite; no real TTS model, network, live Safari data or GUI automation ran. Cleanup refusal and preserved-publication boundaries are synthetic-fixture evidence, not live library proof. |

## October 5 queue lifecycle rework (review follow-up)

A review pass on the queue increment required these corrections, verified by the
narrow filters `rework-core-tests.log` (**25/25 pass**, including the previous 9
queue tests plus legacy cancellation/publication, captured-settings and progress
regressions) and `rework-app-tests.log` (**15/15 pass**). No broad gate or agent
suite was rerun; the broad-gate failures above stand unchanged.

| Area | Rework evidence |
| --- | --- |
| Stop cleanup ordering | `abandonInterruptedWork` now acquires `PipelineLease` before the metadata writer and holds it through filesystem+SQL cleanup. `abandonInterruptedWorkRefusesHeldWorkerLease` (cleanup refuses, work/checkpoints untouched) and `abandonInterruptedWorkRefusesLinkedWorkRoot` (a `p.work` symlink to a temporary-root sibling refuses and deletes nothing) cover the new refusals; the leaf-link test is unchanged. `abandonInterruptedWorkPreservesStagedPublicationBoundary` interrupts at `.audioPlaced` and confirms staged final bytes, encoded/publication metadata and retry work survive an abandon. |
| Stop after real progress | `queueStopAfterFirstCheckpointDiscardsOnlyOwnedWork` commits a first-chunk checkpoint before explicit Stop (checkpoint count 1 → 0, row back to Ready, completed sibling article/feed/snapshot/unrelated files untouched). `queueFailureAfterFirstCheckpointRetainsRowAndContinues` keeps the checkpoint and failed row while a later Ready article still publishes. `queueStopWithArtifactErrorStillAbandonsAndRestoresReady` covers a backend that throws an artifact error while cancelling: cleanup runs and the drain rethrows `CancellationError`. |
| QueueRunControl plumbing | `runQueued` accepts an optional `QueueRunControl` (default `nil` keeps legacy semantics); `AppModel.start(saved:)` and `runQueue()` own and pass controls. Stop controls everywhere gate on `canStopProcessing`. |
| Reset while preparing | `canResetQueue` now covers pending-only queues. Reset clears admission tokens, cancels the enqueue task and awaits its unwind inside `queueMutationTask` before the native reset; `pendingOnlyResetCancelsFetchAndAllowsFreshAdd` confirms a late fetch cannot reappear and a fresh add commits. |
| Ordering and selection | `.running` queue updates remove and re-insert the row at the front. Refresh prunes `queueSelection` to live IDs and commit transfers `.preparation` selection to `.episode`; `queueSelectionTransfersOnCommitAndPrunesOnRefresh` covers transfer, success clearing and stale-ID pruning. `BatchProgressView` takes an optional live pending override. |
| Admission receipts | `QueueAdmissionControl` (cancel flag only) plus optional `SpeechQueueItem.admissionID`; `enqueue`/`enqueueReadingList` check cancellation before `BEGIN` and inside the transaction before `COMMIT`, rolling back with `CancellationError`. `cancelAdmission(id:stateRoot:)` deletes only membership carrying the matching receipt and refuses a `.running` row with an actionable message. `cancelledAdmissionRollsBackCommitAndLeavesNoRows`, `admissionReceiptRemovalIsExactAndRefusesRunningRow` and app-side `removingApprovedAdmissionRollsBackCommit` cover rollback, stale receipts, duplicate re-admission and the commit/remove race (internal `beforeEnqueueCommit` seam). |
| Bootstrap and compatibility | `PipelineStore.init` reuses the bounded writer-busy retry; `pipelineStoreInitWaitsOutBriefWriterContention` holds the writer briefly and confirms the constructor succeeds. `QueueBatchProgress` decodes old progress records missing `pendingPreparations` as 0 (`queueBatchProgressDecodesMissingPendingPreparations`). |
| Second-drain refusal | `queueDrainWaitingForPendingRefusesSecondDrain` rejects a second drain while the first is only waiting on pending preparations — no active TTS required. `queueDrainWithOnlyPendingWorkProcessesCommittedArticle` now starts from a genuinely empty native queue. |

A final review pass (`rework-final-tests.log`, **8/8 pass** — rerun of the prior
narrow set plus additions) refined three points: `abandonInterruptedWork` treats
an `lstat` failure on the owned work directory as fatal unless it is `ENOENT`, so
inaccessible scratch (for example a permissions failure) refuses with an
actionable error before any database change instead of wiping checkpoints
(`abandonInterruptedWorkRefusesInaccessibleWork`); the enqueue commit seam is an
actor-isolated property set via an internal `setBeforeEnqueueCommit` method; and
`removeQueueEntries` restores only selection IDs that are still live after a
failed mutation while Articles blocks adds during queue mutations. Operator
documentation now reflects that explicit Stop returns the row to Ready (no
Retry) and never cancels pending preparations, that error/Quit retention still
uses Retry, and that article inspection is an Articles double-click preview.
`xcodebuild-final.log` records **BUILD SUCCEEDED** for the final incremental Debug build.

## October 5 UI polish: progress lifecycle, icon navigation and compact Troubleshooting

The user reported a completed 5/5 progress bar remaining visible in Articles,
Queue and Saved Audio after processing went idle, and rejected the segmented
Settings picker: the Apple Music–style reference shows an SF symbol above a
label, selected icon and label on a neutral rounded-rectangle glass tile,
unselected items gray. Troubleshooting should lose its redundant saved-article
list and Preview/URL entry; glass belongs on controls, not content.

| Area | Evidence and limits |
| --- | --- |
| Progress lifecycle | `AppModel.finishProcessing` now clears `progress` and `batchProgress` unconditionally on success, failure, cancellation and shutdown; results, saved episodes, status and errors are preserved. New `showsProcessingProgress` (`running || cancelling`) gates `processingFraction` and `ProcessingSummary` placement in `WorkspaceView` — `ProcessingSummary` guards itself too; `processingStatusLine` keeps its existing running guards so the status message is preserved, not hidden. No timer/sleep dismissal; durable results, feed, history and files untouched. Regression `successfulQueueRunClearsTransientProgressButPreservesSavedAudio` failed red on the old code (`batchProgress` stayed non-nil, `success-before.log`) and passes now; `processingSummaryOnlyAppearsDuringOwnedWork` covers idle, running and cancelling states (shutdown/stopping-flag paths are covered only by the unconditional clear, not by that test); the resume test asserts cleared progress after a successful saved-episode run. |
| Settings icon navigation | The segmented picker is replaced by `SettingsPaneSelector`: two fixed 146×82 tiles (VStack, symbol above label, spacing 6) in an HStack of 8 inside `GlassEffectContainer`, total 300×82, centered under a fixed 28pt heading. The selected tile uses `.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))` with `glassEffectID` for a shared transition; plain button style, accent vs secondary colors, `.isSelected` trait, per-pane help. Selection animates `.smooth(0.2)` unless `accessibilityReduceMotion`. Window stays 880×680. Constructability/constant coverage only — rendered glass, focus rings and click positions are unverified. |
| Compact Troubleshooting | `SourceReviewView` is now a grouped-form Reading List diagnostic: source path or "Safari Reading List" (copyable, with full-path help), status, inline error, Refresh/Choose/Stop Loading and a strictly read-only caption. `SourceReviewModel.selection`, `address`, `selectedEntry` and the open-preview plumbing are deleted; Articles remains the only Article Preview entry point (double-click/context menu unchanged). Named preview is "Troubleshooting — source status". The inert-construction test compiles the view and seeds status/error state only — it does not assert which controls render; absence of the old list/URL/Preview UI is established by source review, not by the test. |
| Saved Audio controls | Play/Show in Finder row buttons are wrapped in `GlassEffectContainer` with small `.glass` button style; visibility/availability rules, paths, help and polling unchanged. No glass on lists, text, forms or error cards. |
| Tests | Focused filter (`polish-tests.log`, ignored `var/validation/2026-10-04-ui-polish/`): **13 app tests passed, 0 skips** — new success/visibility/settings/troubleshooting cases plus existing failure, cancellation, resume, queue-reset and workspace tests. Not a full suite; prior 70+15 and 9+4 runs stand as recorded. |
| Build | `xcodebuild` Debug `VoiceRelay`, prior recipe/DerivedData (`xcodebuild.log` in the same directory): **BUILD SUCCEEDED**. Compile evidence only — no rendered layout, clicks or runtime behavior. Only pre-existing warnings: signed-agent strip skip and AppIntents metadata skip. |
| Limits | GUI/Canvas rendering, actual glass appearance, keyboard navigation, listening, TCC prompts and Safari access remain operator gates. The screenshot-reported stale bar is addressed by code and state assertions, not visual proof. |

## Retired prototype foundations: October 1–4

The earlier migration, sample-speech UI, chosen audio-folder workflow, age-based
retention, agent/XPC prototype and standalone AppKit layout probes are retired.
Their lengthy development runbooks and obsolete acceptance steps were pruned
October 10; repository history retains the original records. They must not drive
current implementation or testing.

The shared Swift core and explicit isolated CLI fixtures remain. Early source,
semantic/narration and restartable speech checks established prototype mechanics;
operator-confirmed Kokoro speech subsequently replaced the app's sample/tone
workflow. Whole-number speed decoding, caption/footnote preparation and pinned
runtime setup corrections remain in current code/tests. The Python download
catalog, conflicting uv-preference removal and hashed docopt build exception are
already implemented, not outstanding installation fixes.

Early Xcode project checks found duplicate build-file identities, which motivated
the still-required unique-reference regression. Beta menu/status-item layout and
linkd/Intents diagnostics were investigated with SwiftUI and native AppKit control
projects; those traces did not establish an app-specific root cause or prove GUI
acceptance. The control projects are now removed. An MLX/Metal helper abort was
localized beyond startup, but later speech success did not establish disabled API
Validation as its fix. Current scheme/runtime guidance is in
[KOKORO_PROVIDER.md](KOKORO_PROVIDER.md#xcode-only-metal-failures).

Agent contract/self-check and read-only client fixtures were static foundation
evidence, never proof of service enrollment or execution-context acceptance.
The agent and its tests were removed October 10 because the running app owns all
work. No old agent enrollment, scheduled local-hosting cutover, Python schema
migration, folder chooser or retention validation remains an acceptance gate.

## October 10: Uploads outbox and state filters

Implemented Articles → Uploads → Server Audio navigation, inert outbox previews,
per-item transfer/local/server verification stages and independent native state
filters with counts. URLSession delegate reports actual sent bytes with throttling;
100% transferred does not certify media integrity or RSS publication. Normalized
presentation settings and their identity are cached per edit, avoiding repeated
URL normalization/hashing during row filtering and byte updates.

The pictured selected-file error originates in local identity/size/hash checks,
not evidence of partial TTS or an authentication failure. Publishing now collects
cleanup failures per item, persists sanitized diagnostics and continues other
cleanup. Altered/unowned files remain untouched. Confirmed server history survives
cleanup failures. A repaired local copy can retry verification; server-blocked and
other terminal failures retain their existing policy. Failed remote removals carry
per-item details and appear under Needs Attention in Server Audio.

Validation: the comprehensive isolated run passed 87 selected core checks and
all 102 app-model checks. After the final presentation-cache change, 5 focused
core checks and 6 focused app checks passed. Coverage includes substituted-file
retention and independent cleanup, issue clearance after repaired bytes, partial
feed publication and reused media, measured progress forwarding, independent
filters, current-destination status, removal failures, inert controls and the
Xcode unique-reference regression. The unsigned Xcode Debug build succeeded,
with the existing AppIntents metadata-extraction notice. Local documentation
checks passed (16 Markdown files, 70 links/anchors); git diff --check passed.
Private logs: var/validation/2026-10-10-upload-outbox/.

No app launch, Canvas rendering, protected Safari/Keychain access, live server
request, real speech generation or live-state migration occurred. Operator
acceptance: UI_ACCEPTANCE.md section 5. The preexisting Xcode workspace pin file
was restored exactly after compilation.
