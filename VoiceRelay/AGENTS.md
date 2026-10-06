# VoiceRelay development

This directory is the canonical root for the Swift/macOS application. Inspect the
engineering brief, implementation plan, and validation record in `docs/` before
extending a slice. Keep the independently testable Swift core shared by the Xcode
app, diagnostic CLI, and Swift package tests.

Current user-confirmed lifecycle: processing and retention are owned by the
running VoiceRelay app. Closing a panel or window does not stop work; Quit stops
and awaits owned work. Relaunch restores durable state but starts no speech until
an explicit user action. Persistent LaunchAgent/XPC ownership and SMAppService
enrollment are no longer required. Preserve the dormant agent prototype as
inactive reference code; do not reintroduce it into active UI or enroll it.

Current UX direction: a native MenuBarExtra menu and one sidebar library window
(Articles, Queue, Saved Audio). Settings uses native pane navigation for General
and Troubleshooting, with no global Cancel. Generate/Stop live with audio work.
Keep voice, speed, audio folder, retention and source choice as user preferences;
technical encoding/runtime/feed details stay internal or diagnostic. Use standard
macOS controls, toolbars, sidebar and semantic typography/colors. Liquid Glass
belongs to navigation/control chrome, not content backgrounds. Remove retired
active UI, state, callbacks, scene wiring and previews; retain core fixture/CLI
coverage and dormant agent references.

Current storage/UI direction: General and Troubleshooting share one fixed
880×680 Settings window switched by a centered compact icon-navigation strip
(196×46 selector, 16pt SF symbols, 12pt labels, the selected tile using a real
SwiftUI glassEffect); selection state is the glass tile, and keyboard focus is
shown by a rounded keyboard-only focus cue, not a persistent tinted box. All visible app text
is 12pt or larger (system tooltips excepted); explanatory prose lives behind
ⓘ help controls on section headers, not inline footnotes. Keep macOS27
minimum. There are no visible Refresh controls anywhere: the chosen Reading
List source is re-read automatically (every ~30 seconds, on Articles appearance
and on source selection) while the app runs, and saved-audio/library state
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
pane resets require confirmation. Queue and Saved Audio share one selection-management
control — reset below two selections, Remove Selections at two or more — and one
row-removal button; per-row mutation state is tracked per entry so a removal never
flips global running/progress or disables unrelated controls. Queue rows open the
same Article preview window by double-click or context menu, resolving the URL
from the saved snapshot; the preview window then fetches the page as for Articles. A per-library filesystem lease permits exactly one
speech worker while background metadata writes proceed. Batched runs reuse one
prepared speech-helper session across identity-compatible items; helper failures
surface privacy-safe, role-specific errors without paths or content. Safari
Reading List plist and its entries are strictly read-only: never delete, rewrite
or mark source entries read. The former exclusion feature is removed: saved inventory
never blocks enqueue/retry and legacy excluded/paused rows are retryable. Reset
Queue is explicit and confirmed, removes only native queue membership, and
preserves source inventory, article snapshots, audio and preferences. Saved Audio
shows only existing,
accessible finalized native files; listening uses Show in Finder (Quick Look or
Finder double-click), with no in-app play control. Its row × and Remove
Selections delete the
associated audio file and retire it from the local feed after hash/identity
verification, while confirmed Reset Saved Audio deletes every shown file; article
text, identity and source inventory are preserved for regeneration. Retire confirmed
externally deleted media from
visible listings and the local feed, preserving text/identity for explicit regeneration;
never treat an unavailable volume, unreadable folder or linked path as deletion.
Native metadata uses SQLite WAL with persisted sidecars so read-only connections can
open and read concurrently with writers; future backups must use the SQLite backup
API, never raw database copies.
Processing and inference-helper scratch use app-owned macOS system temporary storage.
Persistent runtime/model/cache assets and explicit installer scratch remain project-local.
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
