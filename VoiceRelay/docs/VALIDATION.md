# Validation evidence

Current results are below. [Historical validation](VALIDATION_HISTORY.md) preserves
October 1–9 evidence, including retired prototypes; it does not describe current acceptance.

Current documentation was reconciled October 11, 2026. Entries below record what
was checked at their stated date; older UI names, commands, signing results and
limitations are historical evidence, not current operator instructions. Use
[README](../README.md), [beta checks](BETA_TESTING.md),
[UI acceptance](UI_ACCEPTANCE.md) and [server recovery](SERVER_RECOVERY.md) for
current workflows. The newest code-validation results precede the older entries.
Documentation-only checks are recorded separately and are not a new app build.

## October 11: remove Settings upload action and investigate hangs

Removed Publishing settings' Upload Now button and its inline URL-commit/forced-
delivery action. There was no separate implementation to delete: automatic
publishing, Sync Now and outbox/history retries share the delivery engine and
remain available. Updated current guidance and folder errors; historical evidence
retains the former button name.

The direct call synchronously read/decoded the private publishing ledger on the
main actor before creating its task. Moved this readiness read to the existing
coordinator, without renaming corrupt state during the probe. New speech waits
behind a neutral preflight gate; startup/explicit reconciliation skips redundant
readiness I/O. Force also intentionally bypasses fresh media proofs unless strong
validators establish unchanged copies, potentially downloading and validating
many episodes sequentially. Sync Now reuses fresh proofs and ordinary backoff.
This explains a possible long busy phase, not a proven main-thread freeze. Network
operations are asynchronous/bounded; inspection runs in detached tasks.

- Initial button-removal checks: **3 core + 7 app tests passed**.
- Preflight investigation checks: **2 core + 8 app tests passed**, including four
  coalescing cases (ordinary, backoff, force, explicit check). A deliberately held
  preflight ran off the main thread while a separate main-actor heartbeat ran;
  subsequent coalesced delivery completed and cleared its gates. Core coverage
  checks destination/cadence and preservation of corrupt ledger bytes.
- Final **all 135 app tests passed** (75.255 s), including Sync, shutdown, restore,
  outbox controls, automation and selection regressions. Signed Release build and
  packaging verification passed; `dist/VoiceRelay.app` is ready for manual checks.
- Documentation links and `git diff --check` passed. No GUI, Keychain, protected
  source or real-server tests ran. No production hang/crash was reproduced.
  Operator checks: confirm no Settings upload action, run popover Sync Now and
  verify Settings/library selection remains responsive. If a true freeze recurs,
  capture an Activity Monitor Sample Process report before quitting.

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --cache-path "$PWD/.build/swiftpm-cache" \
  --disable-sandbox --skip-update --no-parallel \
  --filter 'deliveryPreflight|directPublishingPreflight|deliveryCoalesces|deliveryShutdown|manualSync|deliveryPaneAndAutomation|serverRecoveryCachedScan'
```

## October 11: Articles selection responsiveness

Selection-dependent toolbar/focused-action validation formerly rebuilt the sorted
source/job union repeatedly, and rows installed a competing double-tap recognizer.
Articles now creates one fresh content projection with an identity/display-order
lookup. A child selection view updates controls without invalidating that parent;
source, queue, filter and search updates still rebuild current content. Native
List selection-context-menu primary actions handle double-click previews. Shared
removal/selection controls remain; no custom highlighting/effects layer was added.

- **12 focused tests passed**, then **all 134 app tests passed** (69.600 s).
  New regressions use Observation tracking to prove selection changes update
  actions without invalidating Articles content in both scopes, while queue changes
  still invalidate it. They cover filtered/hidden selections, display order,
  removed identities and additions without a persistent stale index.
- Isolated Debug fixture timings for selection binding/action validation fell
  from 49–62 ms to 0.2–0.5 ms at 500 queued rows, and 193–201 ms to about 0.5 ms at
  2,000 queued rows. These are computation timings, not rendered click latency;
  fixtures use synthetic data and no GUI, protected input, server or speech.
- Unsigned Xcode Debug and signed Release builds passed. The packaging script
  verified signing and produced `dist/VoiceRelay.app`; nothing was installed or
  launched. Documentation links and `git diff --check` passed.
- Operator checks remain: repeated row clicks, keyboard/multi-selection, filtered
  Add/Remove counts and right-click/double-click preview in both scopes, compared
  with Server Audio. See [UI acceptance](UI_ACCEPTANCE.md#1-articles-and-queue).

Focused command:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --cache-path "$PWD/.build/swiftpm-cache" \
  --disable-sandbox --skip-update --no-parallel --filter VoiceRelayAppTests
```

## October 11: final polish implementation

The [approved checklist](FINAL_POLISH.md) now tracks completed code/documentation
work separately from operator and distribution gates. Changes include per-row
queue snapshot failures, coordinated restored-catalog reload, authenticated feed
hash readback, coalesced settings ledger writes, fresh dictionary-based article
projections, bounded audio staging and atomic verified app packaging. Presentation
is split into AppPresentation.swift, SettingsViews.swift and MenuBarViews.swift.
Removed the unused app resume path and inert persistence flag, replaced public
prototype wording and removed four identified inactive generated agent products
(after verifying the installed running app uses a different bundle). Compatibility
paths, pins, notices, runtime assets, preferences and live data are preserved.

Commands, from the repository root:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --cache-path "$PWD/.build/swiftpm-cache" \
  --disable-sandbox --skip-update --no-parallel
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s runtime/kokoro/tests
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests
python3 scripts/check-docs.py
bash -n scripts/build-app.sh
git diff --check
xcodebuild -project VoiceRelay.xcodeproj -scheme VoiceRelay -configuration Debug \
  -derivedDataPath "$PWD/.build/recovery-xcode" \
  -clonedSourcePackagesDirPath "$PWD/DerivedData/SourcePackages" \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
bash scripts/build-app.sh release
```

- Full serial Swift run: **290 core + 132 app tests = 422 passed** (225.898 s /
  72.645 s). Includes unique Xcode references, snapshot fault isolation (mixed,
  all-broken and deterministic late admission), already-loaded/in-flight restore,
  feed mismatch/truncation/limit handling, pending-delete gating, settings
  coalescing/shutdown and existing cancellation/encoding regressions. The first
  run found one new fixture that prepared directories without opening a database;
  corrected it before the final full pass. Existing Swift warnings concern a
  deprecated skip-update option and sandboxed user-level SwiftPM caches.
- After the full pass, clarified the snapshot failure message so it does not
  suggest re-admission can repair corrupted retained text. Three focused core
  queue tests and the captured-settings app queue test passed again. Queue
  previews were colocated with ArticlesView while keeping them synthetic/inert;
  three focused reference/typography/filter tests and final Debug/Release builds
  passed after that source-only move. Documentation checks cover 18 Markdown
  files and 92 local links/anchors.
- **22 offline Python provider/setup tests passed**; **3 packaging tests passed**
  using fake build/copy/signature tools. Failed build/copy/signature checks preserve
  the previous package, successful exchanges remove obsolete contents, and a
  symlink destination is rejected. No GUI/build/signing occurs in these fixtures.
- **Unsigned Xcode Debug build passed**; **signed Release packaging passed**, with
  the existing AppIntents metadata warning (no AppIntents dependency). Development
  signature verification passed with hardened runtime and the application identity
  used by Data Protection Keychain. The packaged version remains 0.1.0/build 1;
  Acknowledgements and immutable installer resources are present, agent executable
  absent and staging directories cleared. This is not Developer ID/notarization.
- Markdown links/anchors and whitespace checks passed. Current evidence is now
  separated from [October 1–9 historical validation](VALIDATION_HISTORY.md).
  Contributor and release guidance are linked from README. Dependency pins remain
  unchanged; no model download, certificate creation, GUI launch or server operation.

The same Debug synthetic projection probe used in the assessment evaluated
website counts, visible rows and website options with every source queued.
For 2,000 rows it improved from 1740.3 ms to 70.6 ms; the new shared render projection
measured 28.8 ms. At 500 rows the equivalent getters measured 27.5 ms (baseline
121.7 ms), and the shared render projection 7.9 ms. This is a single fixture
measurement, not Release profiling, frame timing or actual UI acceptance.
The probe used temporary/inert state and no source reader or network.

Operator acceptance remains in [final polish](FINAL_POLISH.md#results-and-next-validation),
[beta checks](BETA_TESTING.md) and [UI acceptance](UI_ACCEPTANCE.md). GUI/Canvas,
protected Safari, Keychain, real runtime installation/inference/listening and
live DAV/public mapping/Overcast were not tested. No live state was reset or restored.

## October 11: retired development files and private signing configuration

Removed the five retired browser design-study files and their layout checker.
Current layout/accessibility guidance now lives in ARCHITECTURE.md and
UI_ACCEPTANCE.md. Updated stale recovery-review instructions and the
Troubleshooting tooltip, and recorded the user's successful daily-use UI and
unattended-operation report separately from operator checklist results.

Removed the two shared project-level team assignments after confirming they
matched the ignored local configuration. Debug and Release continue to load that
private file; README now directs team assignments there exclusively. Read-only
Xcode build-settings checks confirmed the inherited team, automatic signing,
Apple Development identity, bundle identifier and entitlements remain unchanged
for both configurations. This was not a signed build or certificate repair.

- Four focused Swift tests passed: unique Xcode source/build-file references,
  optional private signing configuration, inert workspace construction and
  typography/selector constants. The app compiled through the package tests.
- All 22 Python provider/setup tests passed with mocked CPU-only services.
  Documentation checks passed (14 Markdown files, 63 local links/anchors), and
  `git diff --check` passed. Workspace dependency pins were restored exactly.
  Private logs and sanitized signing results:
  `var/validation/2026-10-11-development-cleanup/`.
- Active diagnostic CLI/fixtures, process-recovery tooling and dependency notices
  remain. No private runtime assets, configuration, library state, published
  audio or build artifacts were removed. No GUI/Canvas, protected-source,
  Keychain, live server, speech or listening checks ran.

## October 10: popover hover, dismissal and tighter row pairs

Enabled menu actions now highlight their complete row on hover/press with system
selection colors; disabled actions and noninteractive status/progress do not.
Articles/Server Audio and Settings/Quit have half their prior vertical text gap
(4pt row padding and 1pt spacing). Window-opening actions, including failure
status, order out only the weakly captured popover host before activating/opening
the requested scene. Sync stays open for progress. The zero-size attachment is
inert in previews and does not mutate SwiftUI state or activate during layout.

- Eight focused app tests passed, including expanded inert menu/progress
  construction, unattached dismissal, health, one-shot Sync and lifecycle checks.
- Unsigned Xcode Debug build passed with the existing AppIntents metadata warning;
  workspace dependency pins were restored exactly. Documentation checks passed
  (16 Markdown files, 71 links/anchors); `git diff --check` passed. Private logs:
  `var/validation/2026-10-10-menu-hover/`.
- No GUI/Canvas, protected-source, Keychain, live server or listening checks ran.
  Hover appearance, keyboard focus and dismissal/reopening with both newly opened
  and existing target windows remain manual steps in UI_ACCEPTANCE.md.

## October 10: compact menu popover and one-shot Sync

The menu now contains verified overall status, Sync Now, Articles, Server Audio,
Settings and Quit VoiceRelay with two dividers. The user approved a compact
MenuBarExtra window-style popover for a native progress bar. Sync owns a coalesced
source refresh, server check, admission, generation and publishing task, even when
automatic admission/processing are off, without changing those preferences.
Its button becomes phase progress: measured generation/current-file transfers and
indeterminate checks/preparation, returning after completion or cancellation.
Ready requires all three session service verifications; failures open the affected
Settings pane. Startup verifies an installed speech runtime offline. Credential
and destination edits invalidate old connection proofs, including in-flight ones.

- **131 app tests and 61 publishing/server core tests passed.** Seven new app
  regressions cover automation-off one-shot publication, duplicate calls,
  recorded/failed-row exclusions, repeated Sync without new media PUTs, source-read
  failure preserving inventory, Stop/Quit, inert/review guards, health routing,
  stale credential proofs and measured phase progress. The coalesced delivery test
  adds explicit-check coverage. Eight focused test functions (including its four
  parameter cases) passed before the full relevant suite.
- **Unsigned Xcode Debug build passed**, with the existing AppIntents metadata
  warning. Original workspace dependency pins were restored exactly. Documentation
  links/anchors and `git diff --check` passed. Private logs:
  `var/validation/2026-10-10-menu-sync/`.
- Tests use synthetic tone providers and fake source/credential/transport services.
  No live Safari, Keychain, server, speech, listening, GUI or Canvas checks ran.
  Popover focus/rendering, live Ready/failure routing, automation-off Sync and
  progress remain operator steps in UI_ACCEPTANCE.md. No project-file change.

## October 10: durable Server Audio ordering and changing-content projections

Server Audio previously inherited database insertion order. It now explicitly
sorts captured Reading List saved dates newest first, undated last, with stable
episode-ID ties independent of reload/event order. Episode fields supply origin
and date even after source inventory/cache removal. Worker saves and upload
progress retain known origin/date/identity when incoming snapshots omit them.
Search and filters continue to project current episode/status records by stable
identity without a separate source index.

- **121 app tests and eight focused core tests passed**, covering saved-date vs
  generation-date order, ties/undated records, reversed reloads, source removal,
  additions/removals, metadata/progress changes, current search/status results,
  durable legacy-origin capture across cache cleanup and reopening, stale saves,
  episode dates in RSS, backup/restore and server preservation.
- **Unsigned Xcode Debug build passed** with the existing AppIntents metadata
  warning. Original workspace dependency pins were restored exactly. Documentation
  checks passed (16 Markdown files, 71 local links/anchors); `git diff --check`
  passed. Private logs: `var/validation/2026-10-10-server-sort/`.
- No GUI, protected Safari, Keychain, live server or listening checks were run.
  Signed-app display/order and real-source removal remain operator checks in
  UI_ACCEPTANCE.md. Audio bytes and server feed/media were not changed.

## October 10: Server Audio reset placement

Reset Server Audio now appears only in Actions (…) below two selections; Remove
Selections stays in the toolbar for multiple selections. Confirmation, captured
visible-item targets and deletion guards are unchanged. Swift app compilation and
two focused selection/removal tests passed; documentation/link and whitespace
checks passed. Menu placement and confirmation rendering remain manual checks in
UI_ACCEPTANCE.md. No GUI, Safari, Keychain or real server interaction was performed.

## October 10: Reading List removal and saved-date filters

Successful source refreshes now drop absent articles, persist local cache-removal
intent and hide matching queued work. The app cancels pending admissions and joins
owned speech before deleting snapshots, checkpoints and validated scratch. It
preserves server episode history, feed membership and unconfirmed finished audio;
ordinary media/feed-confirmed cleanup releases eligible local copies. Failed reads
preserve inventory, item cleanup failures retry independently, and restore review
delays physical cleanup. Today/This Week precede website filters and use local
calendar saved-date boundaries, including DST and locale week starts.

- The full regression run passed **118 app tests**. Of 282 core tests, two older
  absence/backup fixtures needed the new source policy and were corrected; their
  focused rerun passed. One pre-existing project signing test still fails because
  shared DEVELOPMENT_TEAM settings exist in the unchanged Git HEAD project. No
  signing configuration was edited for this task.
- The final **10 focused tests passed**: durable source removal, interrupted queue
  backup/restore, active-speech and pending-admission cancellation, restore review,
  lease/symlink safety and independent cleanup retry, server/feed preservation,
  unconfirmed audio retention, saved-date period boundaries and scope/search
  combinations. In-memory WebDAV and synthetic audio are mechanical evidence,
  not live Safari, real speech or real-server acceptance.
- **Unsigned Xcode Debug build passed**, with the existing AppIntents metadata
  warning. The exact original workspace dependency pins were restored afterward.
  Documentation checks passed (16 Markdown files, 71 local links/anchors), as did
  `git diff --check`. Private logs are in `var/validation/2026-10-10-source-removal/`.
- GUI menu layout, protected Safari reads and real server/media preservation
  remain operator checks in [UI acceptance](UI_ACCEPTANCE.md).

## October 10: Safari Reading List picker location

The automatic source default remains ~/Library/Safari/Bookmarks.plist. The chooser
previously left its starting directory unspecified, allowing macOS to restore a
location such as Documents. It now explicitly starts at the selected source's
parent folder, falling back to Safari's folder, prefills the filename and shows
hidden files. Explicitly chosen source preferences remain unchanged.

- Swift app compilation and **two focused default/picker policy tests passed**.
  No dialog was opened or protected Safari file read; native panel placement is
  an operator check in UI_ACCEPTANCE.md.
- Documentation checker passed: 16 Markdown files and 70 local links/anchors;
  `git diff --check` passed. No additional Xcode or live-source acceptance was run.

## October 10: source defaults, speech verification and library search

General now owns Reading List selection/diagnostics; Troubleshooting keeps backup
and debug tools. Production preferences default to Safari's Bookmarks.plist while
preserving selected sources; isolated/inert models do not adopt protected input.
Speech setup replaces the ambiguous installation status with a session test
indicator adjacent to Check. Its controls no longer use the broad backup busy
gate, which disabled them during background publishing/source/library refreshes.
Active audio, setup, quitting and library maintenance still block runtime work
with an explanation. Fixed debug events record checks/installations, and cancelled
checks do not invalidate an otherwise usable runtime. The supplied log contains
publishing activity but no runtime-check events; the gate diagnosis comes from
source inspection and isolated reproductions, not a captured live button state.

Native search covers visible title, origin/date, status, error and audio/progress
metadata alongside Website/state filters, preserving independent scope queries
and row order. Selection actions omit hidden rows; automatic work remains global.
Narration collapses consecutive repeated table/code omission announcements across
silent separators. Source content and footnote/prose boundaries remain intact;
unfinished narration upgrades retain compatible chunk proofs, and published audio
is preserved.

- **113 app tests and 12 core narration/extraction/logging regressions passed**,
  including the new defaults, runtime busy-gate/outcome, search, omission-run tests
  and existing checkpoint reuse/queue upgrade coverage. Tests used isolated state,
  fake runtime operations and fixture audio; no protected Safari read, real model
  check/install, credentials or server access was performed.
- **Unsigned Xcode Debug build passed** (`CODE_SIGNING_ALLOWED=NO`). The existing
  AppIntents metadata-extraction notice remains. Workspace pins were restored to
  their exact pre-build state; no app was launched.
- Documentation checker passed: 16 Markdown files and 70 local links/anchors;
  `git diff --check` passed. Native search/Settings rendering, real runtime checking
  and subjective narration acceptance remain operator checks in UI_ACCEPTANCE.md
  and BETA_TESTING.md. Named inert speech-result previews are provided but unrendered.

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

## October 10: startup reconciliation and actionable Publishing notices

A per-session startup check bypasses the persisted five-minute scan gate without
forcing repeated media validation or overriding upload retry delays. The preflight
blocks new generation while inspecting existing server audio. Readiness rendering
remains free of credential/network queries; startup displays Checking Publishing
and healthy completion clears the notice. Publishing failures keep Review
Publishing… alongside Uploads issues and open the Publishing settings pane.
Authentication, Keychain access and permissions retain fixed, sanitized diagnostics.
Fresh library ownership is established before the first reconciliation ledger write;
settings edits do not create a delivery ledger before library records exist.

Validation: all 124 isolated app-model tests and 61 selected publishing/server
reconciliation core tests passed. New regressions cover fresh-state recovery,
relaunch within five minutes with no pending work, one credential read per session,
reused media proofs, missing/unavailable/rejected credentials, no automatic reprompt,
Publishing routing alongside outbox errors and upload backoff preservation. Existing
restore/inert-model and queue-before-generation checks passed. The unsigned Xcode
Debug build succeeded with only the existing AppIntents metadata-extraction notice.
Documentation links and git diff --check passed. Private logs:
var/validation/2026-10-10-startup-reconciliation/.

No GUI/Canvas, real Keychain/Safari, live server, speech or live-state migration was
tested. Operator acceptance: UI_ACCEPTANCE.md section 2, including rapid relaunch
and direct settings navigation after failed authentication. Workspace dependency
pins were restored exactly after the build.
