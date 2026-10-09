# VoiceRelay development

This directory is the canonical root for the Swift/macOS application. Inspect the
engineering brief, implementation plan, and validation record in `docs/` before
extending a slice. Keep the independently testable Swift core shared by the Xcode
app, diagnostic CLI, and Swift package tests.

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
launch only when automation is enabled. Persistent LaunchAgent/XPC ownership and SMAppService
enrollment are no longer required. Preserve the dormant agent prototype as
inactive reference code; do not reintroduce it into active UI or enroll it.

Delivery is configured in the Delivery settings pane: complete HTTPS Feed folder
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

Current UX direction: a native MenuBarExtra menu and one sidebar library window
(Articles, Queue, Server Audio). Settings uses native pane navigation for
General, Delivery and Troubleshooting, with no global Cancel. Generate/Stop
live with audio work.
Keep voice, speed and source choice as user preferences;
technical encoding/runtime/feed details stay internal or diagnostic.
Audio encoding uses 96 kbps AAC-LC/M4A at mono 24 kHz, with floating-point
intermediates and original levels/dynamics: no normalization, gain, limiter or
DRC. The legacy loudness profile field is inert decoding/import metadata.
Unfinished managed work adopts the current bitrate and encoding policy, reusing
valid speech chunks; encoded scratch is versioned independently. Preserve
published or integrity-confirmed already-placed final audio files.
Use standard macOS controls, toolbars, sidebar and semantic typography/colors. Liquid Glass
belongs to navigation/control chrome, not content backgrounds. Remove retired
active UI, state, callbacks, scene wiring and previews; retain core fixture/CLI
coverage and dormant agent references.

Current storage/UI direction: General, Delivery and Troubleshooting share one
resizable
400×680-ideal Settings window (360×540 minimum) switched by a centered compact icon-navigation strip
(292×46 selector — three 92pt tiles plus spacing, 16pt SF symbols, 12pt labels,
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
notice until the condition resolves or a context reset. Articles, Queue and
Saved Audio live in the sidebar workspace;
Generate/Stop live in the Queue toolbar and status menu. Progress is shown only
while owned work runs or stops; terminal results clear transient progress.
Generate and Reset stay enabled during ordinary row removals; a Generate
request waits for queued metadata mutations to finish before snapshotting the
queue, and confirmed resets queue behind pending metadata work FIFO.
Article preview is a dedicated WindowGroup(URL) window fed by
ArticlePreviewModel, opened only from Articles double-click/context menu; inert
previews never fetch. Troubleshooting is a compact Reading List source
diagnostic with no saved-article list, typed URL or Preview control. Add to
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
retains authenticated voice tensors and bounds allocator reuse at 256 MiB; do not
alter pinned model math or introduce a second inference worker without request. Batched runs reuse one
prepared speech-helper session across identity-compatible items; helper failures
surface privacy-safe, role-specific errors without paths or content. Safari
Reading List plist and its entries are strictly read-only: never delete, rewrite
or mark source entries read. The former exclusion feature is removed: saved inventory
never blocks enqueue/retry and legacy excluded/paused rows are retryable. Reset
Queue is explicit and confirmed, removes only native queue membership, and
preserves source inventory, article snapshots, audio and preferences. Server Audio
is durable episode history, including pending uploads, confirmed remote episodes
and unfinished server removals. New audio is generated in app-owned system temporary
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
Show in Finder remains only for legacy local audio. No hosted-file listing or server
audit is performed; history reflects the app's recorded confirmations.
Native metadata uses SQLite WAL with persisted sidecars so read-only connections can
open and read concurrently with writers; future backups must use the SQLite backup
API, never raw database copies.
Processing and inference-helper scratch use app-owned macOS system temporary storage.
Persistent runtime/model/cache assets and explicit installer scratch remain project-local.
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
content. Upgrade unfinished plans and recompute queue totals; unchanged requests
retain compatible completed-chunk fingerprints. Published audio is preserved.
Optional HTTPS Open Graph/Twitter preview images become per-episode
RSS itunes:image artwork for current Overcast. Reuse the existing SwiftSoup
parser; missing artwork never blocks speech or publishing. Images remain external
publisher URLs, without a secondary image fetch, download or embedding step.
Clean only newly owned helper-session scratch after its worker stops. The one-time
user-approved backed-up native queue/generated-history reset was completed; do not
repeat it or re-query its frozen result as part of validation. No audio files or Safari
input files were deleted by that reset.

- Preserve the Python reference and all customized configuration, state, feeds,
  and published audio in their existing locations. Do not copy live data into
  this project or silently adopt its schema. Use explicit isolated fixtures.
- Keep private endpoints, credentials, model assets, and generated artifacts out
  of source control. Retain pinned dependencies and their redistribution notices.
- Provide named, source-local SwiftUI previews with synthetic, inert states.
- The user does not authorize automated computer use. Do not operate the GUI or
  request Accessibility or Screen Recording access. Perform permitted source,
  build, and focused fixture checks; hand off GUI, protected-file, agent-context,
  listening, and device validation to the user with exact commands or steps.
- Report builds, tests, Canvas rendering, GUI behavior, and live acceptance
  separately. Mock tones are pipeline evidence, never speech acceptance.
- Make the smallest complete change, preserve unrelated work, and update focused
  tests when behavior changes. Do not enroll services, upload feeds, migrate live
  state, or cut over hosting as a side effect of build or startup.
- Testing mode: **autonomous** (confirmed October 4, 2026). Relevant isolated
  source/build/fixture checks run automatically; for agent/client work:

  ```sh
  cd /path/to/VoiceRelay
  CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
  swift test --cache-path "$PWD/.build/swiftpm-cache" \
    --disable-sandbox --skip-update --filter 'agent|Agent'
  .build/debug/VoiceRelayAgent --self-check
  ```

- After editing `project.pbxproj` also run the project-reference regression
  (learned from a duplicate object-ID defect SwiftPM cannot see):

  ```sh
  swift test --cache-path "$PWD/.build/swiftpm-cache" \
    --disable-sandbox --skip-update \
    --filter xcodeProjectAppSourcesUseUniqueBuildFileReferences
  ```

  GUI, Canvas, protected-file, listening, and actual-agent enrollment, context,
  and device validation remain manual operator steps.
