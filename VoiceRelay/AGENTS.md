# VoiceRelay development

The authorized native unification plan in the sibling `swift-packages/docs/IMPLEMENTATION_PLAN.md`
supersedes previous Python/product CLI work. Shared implementation belongs there;
VoiceRelay owns discovery, retained article identity, SQLite and publication.
Speech uses one resident native helper, with no serial/parallel mode or automatic
fallback replay. VoiceRelay requests background admission through the shared lease
and yields between chunks to pending Libro work. Do not change team/Keychain
signing settings merely to produce local ad-hoc test artifacts.
No maintained Python support remains. Audio is never normalized or volume leveled.

October 13 additions: all app scenes use shared semantic typography with persisted
80–200% text sizing, Dynamic Type category scaling and a 12pt floor. General has the
setting; View commands provide ⌘+/⌘−/⌘0. Scale navigation and use a compact selector
fallback at large sizes; avoid view transforms. PDF URLs use local PDFKit text and
bounded Vision OCR. Web ALT and tagged PDF Figure/Alt text take precedence; repeated
image credits are suppressed in narration, without dropping source prose. Missing
descriptions may use available on-device Foundation Models, never cloud fallback or
automatic model downloads. The generated-description preference defaults on and can
be disabled; authored ALT/OCR remain active. Inline web image retrieval is bounded,
public HTTPS only, ephemeral and credential-free; this is separate from external
RSS artwork. Image failures retain article text. Injected/inert loaders must use
explicit fake image providers and never contact image hosts or native models.
Preserve verified snapshots, source identity/save dates and published audio. Native
OCR fixtures may require sandbox escalation for Apple's system ML runtime; actual
image-description quality, GUI and listening acceptance remain operator-owned.

This directory is the canonical root for the Swift/macOS application. Inspect
`docs/README.md`, `docs/ARCHITECTURE.md`, `docs/VALIDATION.md` and the shared
current roadmap before extending the application. Keep the independently testable Swift core shared by the Xcode
app, native helper, and Swift package tests.

Current user-confirmed lifecycle: processing and delivery are owned by the
running VoiceRelay app, and the app's purpose is set-and-forget automation.
Closing a panel or window does not stop work; Quit stops and awaits owned work.
While running, the app automatically admits newly discovered Reading List
articles, processes the ready queue, and drains pending delivery — relaunch
resumes owned work automatically. Explicit Stop suspends auto-processing until
new work arrives or Generate is pressed; failed items stay manual-Retry.
Manual controls remain as overrides. Automatic admission never re-adds entries
with recorded audio, retained snapshots or absent source entries, and a failed
automatic admission is not retried until the next session. Automatic delivery
drains run after publication, retirement/removal, launch and refresh, plus
periodically while the app runs; interrupted queue items are re-readied on
launch only when automation is enabled. Each enabled/configured app session attempts
server reconciliation even if the prior session checked less than five minutes ago;
reuse current audio proofs and keep upload backoff intact. Startup progress is neutral,
and Publishing failures keep a direct Publishing Settings route alongside outbox issues.
Persistent LaunchAgent/XPC ownership and SMAppService
enrollment are no longer required. The inactive agent/XPC prototype and standalone
layout-reproduction projects were removed at the user's request; do not reintroduce them.

Delivery is configured in the Publishing settings pane: complete HTTPS Feed folder
and Public folder URLs plus channel details persist in UserDefaults. feed.xml
and lowercase audio/ are implicit under each folder; the subscription URL is
read-only with Copy. URL drafts normalize when committed using Foundation
URLComponents; no credentials enter URLs or diagnostics. The password lives
only in Keychain ("VoiceRelay Podcast Upload" service). Test Connection is a
manual read-only folder probe; a readable ancestor permits a missing-folder
result saying upload will create it. It does not confirm write permission or
public mapping. Editing inputs resets the test status. Changed destinations
require fresh byte-confirmed copies; preserve old remote files and never apply
old-host deletes to a new destination. Failures use sanitized status text.

Current UX direction: a compact MenuBarExtra window-style popover and one sidebar library window
(Articles with All Articles/Queue scopes, Uploads, Server Audio). Settings uses native pane navigation for
General, Pronunciation, Publishing and Troubleshooting, with no global Cancel. Generate/Stop
live with audio work.
Keep voice, speed and source choice as user preferences;
technical encoding/runtime/feed details stay internal or diagnostic.
Audio encoding uses 64 kbps AAC-LC/M4A at mono 24 kHz, with floating-point
intermediates and original levels/dynamics: no normalization, gain, limiter or
DRC. The legacy loudness profile field is inert decoding/import metadata.
Unfinished managed work adopts the current bitrate and encoding policy, reusing
valid speech chunks; encoded scratch is versioned independently. Preserve
published or integrity-confirmed already-placed final audio files.
Use standard macOS controls, toolbars, sidebar and semantic typography/colors. Liquid Glass
belongs to navigation/control chrome, not content backgrounds. Remove retired
active UI, state, callbacks, scene wiring and previews; retain core fixture
coverage. Remove abandoned prototypes rather than bundling inactive executables.

Current storage/UI direction: General, Pronunciation, Publishing and Troubleshooting share one
resizable
440×680-ideal Settings window (360×540 minimum) switched by a centered compact icon-navigation strip
(392×46 selector — four 92pt tiles plus spacing, 16pt SF symbols, 12pt labels,
the selected tile using a real
SwiftUI glassEffect); selection state is the glass tile, and keyboard focus is
shown by a rounded keyboard-only focus cue, not a persistent tinted box. All visible app text
is 12pt or larger (system tooltips excepted); explanatory prose lives behind
ⓘ help controls on section headers, not inline footnotes. Keep macOS27
minimum. There are no visible Refresh buttons: the chosen Reading
List source is re-read automatically (at startup, every five minutes, on Articles
appearance and on source selection), and through the Articles pull-down gesture,
while the app runs. Articles show newest saved dates first, with stable discovery
order for ties and undated entries last; manual selection enqueues in displayed
order without reordering existing queue items. Saved-audio/library state
rechecks internally. Older diagnostics that mention "refresh Saved Audio" refer
to that automatic recheck / reopening the pane. Inline errors carry a
hover-revealed ⓧ dismiss that is presentation-only: it never mutates stored
errors, snapshots, queue records or history, and suppression is keyed per
notice until the condition resolves or a context reset. Articles (All Articles/Queue scopes) and Server Audio live in the sidebar workspace;
Generate/Stop live in the Articles toolbar (both scopes) and application commands. Progress is shown only
while owned work runs or stops; terminal results clear transient progress.
Generate and Reset stay enabled during ordinary row removals; a Generate
request waits for queued metadata mutations to finish before snapshotting the
queue, and confirmed resets queue behind pending metadata work FIFO.
Article preview is a dedicated WindowGroup(URL) window fed by
ArticlePreviewModel, opened only from Articles double-click/context menu; inert
previews never fetch. General owns Reading List selection and source diagnostics;
new production preferences default to ~/Library/Safari/Bookmarks.plist without
overriding a selected source. Inert/injected models never default to protected
Safari input. Troubleshooting contains library backup and debug tools, with no
Reading List controls. Speech setup shows its session test result beside Check,
independently of detected installation files. Background publishing/source updates
do not disable Check/Install; active speech, quitting, setup or library maintenance
do, with an explanatory reason. Add to
Queue is a background task with pending rows and collected
per-entry issues rather than a synchronous stop. Prepared rows show Ready with a
checkmark; admission keeps working while speech runs. Process Queue drains every
Ready row plus still-pending admissions and late additions until nothing
eligible remains; each verified publication dequeues immediately and a failure
keeps its row for Retry while later Ready items continue. Explicit Stop abandons
only the interrupted item's owned scratch/checkpoints and returns that row to
Ready — never silently Paused — while error and Quit retention stay distinct.
Rows remove individually or by arbitrary multi-selection without confirmation;
pane resets require confirmation. Queue and Server Audio share one selection-management
control — reset below two selections, Remove Selections at two or more — and one
row-removal button; per-row mutation state is tracked per entry so a removal never
flips global running/progress or disables unrelated controls. Queue rows open the
same Article preview window by double-click or context menu, resolving the URL
from the saved snapshot; the preview window then fetches the page as for Articles.
Queue and Preparing rows show the original article host as Articles does. New
queue records capture it; legacy rows recover it read-only from retained source
inventory or the integrity-checked snapshot, without fetching a page. A per-library filesystem lease permits exactly one
inference worker while background metadata writes proceed. The active drain
pipelines at most one synthesizing article with one FIFO CPU finalizer and one
pending chunk validation; it never starts a second inference. Explicit Stop lets
already-started finalization finish while abandoning only interrupted speech;
Quit cancels and joins both stages while retaining recovery checkpoints. Waiting
rows remain Ready/removable until their speech turn starts. Debug logging includes
sanitized stage timings. Kokoro pronunciation lookahead uses one CPU thread,
retains authenticated voice tensors and bounds MLX cache reuse at 64 MiB and working memory at a soft 1 GiB threshold; do not
alter pinned model math or introduce a second inference worker without request. Batched runs reuse one
prepared speech-helper session across identity-compatible items; helper failures
surface privacy-safe, role-specific errors without paths or content. Safari
Reading List plist and its entries are strictly read-only: never delete, rewrite
or mark source entries read. The former exclusion feature is removed: saved inventory
never blocks enqueue/retry and legacy excluded/paused rows are retryable. Reset
Queue is explicit and confirmed, removes only native queue membership, and
preserves source inventory, article snapshots, audio and preferences. Server Audio
is durable episode history, including pending uploads, confirmed remote episodes
and unfinished server removals. Articles, Queue/preparing rows and Server Audio
share the same original-website/Saved-date line. Episode originalSourceHost is
independent of RSS sourceHost/sourceURL; legacy origins resolve read-only from
retained inventory or identity-matching, integrity-checked snapshots. A missing
saved date is omitted from that line, never replaced by the generation date.
New audio is generated in app-owned system temporary
storage; delete its local copy only after both byte-confirmed media upload and
confirmed feed membership for the current destination. Commit cleanup intent
before unlink, verify hash/size/file identity, and never retire an episode just
because its temporary copy is gone. Existing VoiceRelay audio is also eligible for confirmed-upload cleanup;
never delete unrelated files or an unconfirmed copy. General has no Storage section,
folder chooser or scheduled retention policy. Missing unconfirmed temporary output
is requeued from retained article snapshots, preserving GUID and captured voice;
failed rows remain manual Retry. Destination changes recreate released bytes from
retained text and preserve old-host copies. VoiceRelay's Server Audio ×/Remove
Selections and confirmed pane reset retire feed membership before remote deletion;
keep pending server removals visible until confirmed. Upload New Items appears only
for pending audio/publication, disables during delivery and hides after confirmation.
Show in Finder remains only for legacy local audio. Server Audio normally reflects recorded confirmations. Explicit Publishing → Check
Publishing automatically reconciles bounded authenticated feed/media before queued
generation and through ordinary delivery, with no separate Check Server Audio UI.
Use original-source identity or unambiguous retained links, streamed SHA-256,
format inspection and full decode. Prefer longer valid copies at comparable
voice/speed; retain the server copy for ties or known variants. Preserve losing
server files; local replacements get fresh opaque identities. Item failures retain
existing feed membership and continue unrelated work with sanitized diagnostics.
Whole-feed failures block feed replacement/deletes, not unrelated fresh uploads.
Five-minute cadence/backoff, changed queue/destination gates and cached proofs
avoid unneeded work; unchanged proofs expire after 24 hours or use strong server
validators. Restore review still gates all changes. No directory-wide orphan
listing, title-only matching or arbitrary enclosure fetches.
Native metadata uses SQLite WAL with persisted sidecars so read-only connections can
open and read concurrently with writers; future backups must use the SQLite backup
API, never raw database copies.
Processing and inference-helper scratch use app-owned macOS system temporary storage.
Persistent runtime/model/cache assets and explicit installer scratch remain confined
to the selected runtime root: legacy project-local installations remain supported;
explicit General installation uses the private app-managed SpeechRuntime directory.
Bundle the native helper and Metal resources; never download models on build/startup/readiness.
Library backups use SQLite backup, include retained text and delivery bookkeeping,
exclude credentials/preferences/audio/runtime/scratch, and remain private. Restore
validates and stages before atomic replacement, preserves the previous library,
and disables automation/delivery for review; a persistent review gate also blocks
local cleanup/server changes until Finish Library Review. No live state is restored by tests.
Archived-article recovery is optional and off by default. Original fetching and
validation run first; eligible failures can query existing Archive.ph Memento
TimeMaps then Wayback Availability. Never submit captures, solve CAPTCHAs, execute
remote JavaScript or reuse browser credentials. Strip known tracking parameters;
skip other queries and local/private hosts. Restrict archive redirects to known
HTTPS provider hosts with normal TLS validation, bounded bytes and deadlines.
Preserve the original source identity and Reading List save date, record private
capture provenance, reject archive/challenge pages and keep saved text offline.
Archive-origin diagnostics carry fixed outcomes, not URLs or contents. Inert or
injected app models never contact archives without an explicit fake transport.
Narration opens with the article title and source (publisher name, falling back to
host) and ends with a separate "End of article." paragraph; source blocks stay
unchanged. Podcast episode dates and RSS ordering use the Reading List saved date
when available, falling back to the audio publication timestamp. Keep that
publication timestamp independent. Legacy records resolve saved dates read-only
from the catalog using their original source identity; date-only feed changes
republish through ordinary delivery without regenerating/re-uploading audio.
Standalone decorative separators (such as --, bullet and vertical bar) are
retained in semantic blocks but omitted from narration so Kokoro receives spoken
content. Consecutive table/code blocks announce each repeated omission only once,
including across nonverbal separators; authored prose and footnote boundaries stay
intact. Upgrade unfinished plans and recompute queue totals; unchanged requests
retain compatible completed-chunk fingerprints. Published audio is preserved.
Optional HTTPS Open Graph/Twitter preview images become per-episode
RSS itunes:image artwork for current Overcast. Reuse the existing SwiftSoup
parser; missing artwork never blocks speech or publishing. Images remain external
publisher URLs, without a secondary image fetch, download or embedding step.
Clean only newly owned helper-session scratch after its worker stops. The one-time
user-approved backed-up native queue/generated-history reset was completed; do not
repeat it or re-query its frozen result as part of validation. No audio files or Safari
input files were deleted by that reset.

- Preserve private legacy environments and all customized configuration, state, feeds,
  and published audio in their existing locations. Do not copy live data into
  this project or silently adopt its schema. Use explicit isolated fixtures.
- Keep private endpoints, credentials, model assets, and generated artifacts out
  of source control. Retain pinned dependencies and their redistribution notices.
- Provide named, source-local SwiftUI previews with synthetic, inert states.
- The user does not authorize automated computer use. Do not operate the GUI or
  request Accessibility or Screen Recording access. Perform permitted source,
  build, and focused fixture checks; hand off GUI, protected-file, server,
  listening, and device validation to the user with exact commands or steps.
- Report builds, tests, Canvas rendering, GUI behavior, and live acceptance
  separately. Mock tones are pipeline evidence, never speech acceptance.
- Make the smallest complete change, preserve unrelated work, and update focused
  tests when behavior changes. Do not enroll services, upload feeds, migrate live
  state, or cut over hosting as a side effect of build or startup.
- Testing mode: **autonomous** (confirmed October 4, 2026). Relevant isolated
  source/build/fixture checks run automatically. GUI, protected-file, listening
  and real server acceptance remain operator-owned.

- After editing `project.pbxproj` also run the project-reference regression
  (learned from a duplicate object-ID defect SwiftPM cannot see):

  ```sh
  swift test --cache-path "$PWD/.build/swiftpm-cache" \
    --disable-sandbox --skip-update \
    --filter xcodeProjectAppSourcesUseUniqueBuildFileReferences
  ```

  GUI, Canvas, protected-file, listening, and device validation remain manual operator steps.

October 9 approved UI: Articles and Queue share one Articles sidebar destination.
All Articles is a typed source/retained-job union ordered by saved date; Queue
shows every episode/preparation in processing order. Scope changes preserve
independent selections. Already-queued source entries are omitted from manual
Add; history is not a new exclusion rule. Queue removal never deletes source
entries, snapshots or server audio. Publishing replaces the visible Delivery
pane label; internal keys remain compatible. Its setup/recovery strip uses
existing metadata without Keychain/network probes, distinguishes unknown from
missing credentials, and disappears when configured. Configuration is not remote
verification. Generate Audio/Stop names and availability agree across toolbar
and application commands; list Delete is focus-scoped. The restore review gate takes precedence.

October 10 upload outbox: Uploads sits between Articles and Server Audio and shows
tracked completed audio awaiting upload/publication, verification failures and retained
local cleanup conflicts. Speech chunks stay in Queue; no directory-wide file scan.
Transfer byte progress is transient and cannot confirm media integrity or RSS membership.
Clear outbox rows only after current-destination publication confirmation and resolution
of local cleanup verification issues. Persist sanitized per-item cleanup notices and
continue other cleanup/upload work without misreporting a connection failure.
Uploads and Server Audio have independent native state filters with counts; failed
verification includes both server verification failures and local cleanup conflicts.
Server Audio stays durable history, including pending removals; filtered selection
removal/reset targets only visible rows. Retry honors restore review and lifecycle gates.

October 10 follow-up: Uploads × explicitly discards a tracked local copy without
retiring server audio or retained text. Persist intent before safe unlink; automatic
recovery/transfer must skip deliberately discarded copies. Changed bytes are only
removable from the owning library's temporary audio folder. Keep failed removals
visible. Articles/Queue have independent Website filters using Foundation host
normalization and a www display alias; other subdomains remain distinct. Selection
actions only target visible rows; filtering never limits automatic processing.

Explicit local discard also cancels matching native queue membership atomically
with its intent, preventing an interrupted Ready job from recreating the file.
Reading List entries and retained snapshots remain available for manual re-enqueue.
Discarded local copies never become automatic reconciliation replacement winners.

Help copy: keep hover tooltips short and action-focused; section ⓘ hover uses
“About <section>”, with brief popover summaries. Longer publishing/backup guidance
belongs in the shared native Help menu's static topic windows. Keep deletion
consequences and archive/backup privacy visible; do not expose implementation
details unless needed for a user's decision. Help never probes library/server state.

Articles (independent All Articles/Queue scopes), Uploads and Server Audio have
native local search across visible titles, origin, saved date, status and errors.
Search combines with existing filters, preserves row order, scopes bulk actions to
shown selections and never changes automatic processing/publishing membership.

Server Audio's confirmed Reset action lives only in Actions (…) below two
selections; Remove Selections remains a toolbar action at two or more selections.

Server Audio orders captured Reading List saved dates descending, undated last,
with stable episode-ID ties across reload/event order. Persist original host,
source identity and saved date on episodes; missing fields in stale worker saves
or progress snapshots must not erase known values. Server Audio and Uploads
filters/search derive from current episode/status records, not source inventory
indices. Cover source removal, reload, additions/removals and metadata/status
updates with isolated regressions; never fabricate missing saved dates.

Successful Reading List refreshes delete absent source entries from Articles and
Queue and persist cache-removal intent. Cancel pending admissions; stop/join owned
speech for the removed item before purging snapshots, chunk checkpoints and owned
scratch under the pipeline lease. Failed source reads preserve all data. Retry
safe cleanup per item without blocking unrelated work; restore review gates
physical cleanup. Keep minimal durable episode history and unconfirmed finished
audio for publishing. Confirmed media/feed cleanup may release local audio, but
source removal must never retire feed membership or delete server audio. Do not
regenerate absent articles from removed snapshots. Already exported backups stay
unchanged. Today and This Week precede a separator in the Articles filter and use
local Calendar saved-date periods; missing dates do not match. Website sorting,
scope independence and global processing remain unchanged.

October 10 approved menu: compact MenuBarExtra .window popover contains overall
status, Sync Now, separator, Articles, Server Audio, separator, Settings and Quit
VoiceRelay. Ready requires current-session verified Reading List, speech runtime
and WebDAV health; failures link to the affected Settings pane. Pure rendering
never probes services. Check an installed speech runtime offline at startup.
Sync Now explicitly refreshes, admits, processes and publishes eligible work regardless
of automatic admission/processing preferences, without changing them or retrying
failed speech rows. Retain server reconciliation/proof caching and skip recorded
identities. Its button becomes phase progress while owned sync runs: measured
speech/finalization or current-file transfer fractions, indeterminate checks/preparation.
Never invent an overall percentage. Duplicate clicks coalesce; Stop/Quit cancel
and join owned work. Restore review gates Sync; backups/restores wait for it.

Popover actions highlight on hover/press using semantic system selection colors,
without highlighting disabled actions or status/progress labels. Articles/Server
Audio and Settings/Quit have half the original inter-label gap. Window-opening
items, including failure status, dismiss only their captured popover host before
activation/opening; Sync stays open. Host capture is weak, inert in previews and
must not mutate SwiftUI state or activate windows during layout.

October 11 final polish: queue planning fails unusable snapshots per row and keeps
healthy Ready work running. Restore suspends/joins source reads and settings
bookkeeping before swapping libraries, then reloads the catalog for review.
Publishing reads back bounded authenticated feed bytes and verifies SHA-256 before
confirming membership, local cleanup or remote deletion. Settings ledger writes
are coalesced on the coordinator; rendering uses fresh per-render projections.
Audio staging streams bounded buffers; validated same-directory scratch is renamed.
App presentation is split into AppPresentation, SettingsViews and MenuBarViews with
named inert previews. Packaging stages and verifies before atomic exchange; fake
packaging fixtures never build, sign or launch an application. CONTRIBUTING.md and
docs/RELEASE_CHECKLIST.md describe engineering and distribution gates; historical
validation lives separately in docs/history/VALIDATION.md. Do not bump to 1.0 or
operate Developer ID/notarization accounts before operator acceptance/approval.


October 15 shared Settings: use independent AppPresentation navigation, section help,
notices and Appearance controls, plus SwiftNarration.NarrationUI narration controls.
Keep preference keys, source/automation, Publishing, backup and session log ownership
here. Speech setup appears once; Install Speech Model explicitly downloads and
Check Speech Setup initializes offline with joined cleanup. Generic offline failures
must not suggest a network requirement. See the shared SETTINGS_ALIGNMENT.md plan.
