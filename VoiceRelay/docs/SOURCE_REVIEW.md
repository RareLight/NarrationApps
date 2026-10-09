# Articles and local speech — Slice 3 development

Updated October 5, 2026. The sidebar workspace contains **Articles**, **Queue**
and **Saved Audio**. Select entries, **Add to Queue**, then **Generate Speech**.
Selecting entries fetches nothing and requires no article review.
Article inspection opens the dedicated **Article Preview** window: double-click
an entry or use its **Preview Article** menu in Articles. Reading List source
selection is
**Settings → General → Reading List**.

## Optional archived-article recovery

Under **Settings → General → Reading List**, enable **Try archived copies when
articles fail**. This preference defaults off. A new admission or Article Preview
first tries the original site. Recoverable HTTP/network errors and rejected
login, subscription, missing-page, browser-check or extraction results can then
try Archive.ph, followed by the Wayback Machine. Re-select previously unsuccessful
Articles and use **Add to Queue** after enabling it; automatic admission does not
retry a failed entry again in the same session. Already saved text remains offline.

Lookup discloses the public article URL to the archive provider. Known tracking
parameters and fragments are removed; other queries, embedded credentials,
local/private host names, IP literals and nonstandard ports are excluded. This
reads existing captures only. There are no archive submissions, browser cookies,
JavaScript execution, authentication tricks or CAPTCHA solving. A provider error
or unusable snapshot falls through once; failed recovery keeps the original issue
and adds a safe unavailable message. Unsupported document types/size-limit failures
remain failures. Each provider has at most one index and one HTML request, bounded
by ten seconds per request and the existing byte limits. Archive requests and
redirects stay on the provider's HTTPS hosts with standard certificate validation.

When available, captures closest to the Reading List saved date are preferred;
otherwise the latest listed capture is used. Original URL, queue identity, saved
date and publisher narration are retained. Snapshot URL, provider and capture date
stay in the private integrity-checked article snapshot; Article Preview displays
that provenance. Archive chrome is omitted from extraction where identifiable.
Publisher-hosted HTTPS artwork can remain; archive-hosted replacements are omitted.
Nothing about archive provenance is added to RSS. Debug logging records only fixed
provider/outcome events, never lookup URLs or article contents. Cached text can be
older, incomplete, or unavailable; live acceptance remains an operator check.

Research before implementation:

- [archivetoday](https://github.com/HRDepartment/archivetoday) is an unofficial
  JavaScript client exposing TimeMap lookup and capture creation separately.
- [@agntn/archives](https://github.com/agntn/archives), formerly omnichron, is a
  TypeScript adapter over multiple archives and requires Node.js.
- [Memento RFC 7089](https://www.rfc-editor.org/rfc/rfc7089.html) describes TimeMap
  link serialization; Archive.ph's public example.com response confirmed its
  timestamped replay links and `application/link-format` MIME type.
- [Wayback Availability API](https://archive.org/help/wayback_api.php) documents
  read-only lookup, timestamp selection and available snapshot results.
- The supplied RemovePaywall search page could not be retrieved during research;
  no supported automation API was verified, so it is not an automatic provider.

VoiceRelay uses these existing protocols with its bounded Foundation client and
SwiftSoup, without adding a JavaScript runtime or copying third-party library code.

## Queue-first article selection

- A chosen Reading List source is re-read automatically — on Articles
  appearance, on source selection, and roughly every 30 seconds while the app
  runs — without changing bookmarks or Reading List flags; the plist and its
  entries are strictly read-only, never deleted, rewritten or marked read.
  There is no Refresh control. With no source chosen, Articles only loads the
  private saved inventory and asks you to choose a source in Settings. Entries
  and membership persist; failed source reads retain them.
- Select several articles with ⌘-click or Shift-click. **Add to Queue**
  runs as a background task: each selected entry immediately shows a
  *Preparing…* pending row, then entries are captured in displayed inventory
  order with current voice, speed and audio-folder choices.
- New selected articles are fetched, extracted and validated sequentially before
  their text is committed. Adding starts no inference and creates no scratch/audio.
  Already saved articles reuse their stored text offline; duplicates keep identity,
  choices and FIFO position. Removing/readding also reuses saved text. Deliberate
  source revision replacement remains later work.
- A failed entry records a per-entry issue in Articles and does not abort the
  other additions. Earlier committed items remain queued; failed and unattempted
  entries keep their pending row until the task finishes. **Stop Generating** also
  preserves earlier additions. Unsaved selections are UI state, not durable work;
  add them again after relaunch if needed. Blocked/login/consent or unreadable
  pages are refused; inspect them by double-clicking the entry in Articles.
- **Generate Speech** in Queue or the status menu processes waiting items
  FIFO from saved text — prepared rows show a *Ready* checkmark. It does not
  refetch pages. The run drains until nothing eligible remains: it takes the
  earliest Ready row even when earlier admissions are still preparing, waits
  out pending preparations, and processes commits that arrive while speech is
  active, so a late **Add to Queue** needs no second click. Identity-compatible
  consecutive items share one prepared speech-helper session, so the local
  engine/model does not reload between them. A failure keeps its failed row
  and chunk checkpoints but does not stop the run; later Ready items continue.
  Helper failures surface a privacy-safe, role-specific message — no paths or
  content — with completed chunks retained.
- Successful processing automatically removes an item from Queue only after
  audio hash/probe/decode verification and local feed commitment. The episode,
  source and audio remain in Saved Audio. Older completed queue rows are reverified
  on the next explicit Generate Speech command before removal; this is not startup
  processing. Readding a saved episode queues a verification run, preserving its
  captured settings and existing audio.
- **Stop Generating** appears only during owned speech work (including while a
  run waits on pending preparations) and disables while stopping. It clears the
  active/stale progress readout, cancels the worker, abandons only the
  interrupted item's owned scratch and checkpoint rows, and returns that row to
  Ready — never silently Paused. Earlier verified completions stay saved and
  leave the queue; published audio, feeds and source snapshots are never
  removed by Stop. Quit uses the legacy cancellation path instead and retains
  unfinished checkpoints. Failed rows require **Retry → Generate Speech**;
  Retry alone starts no inference. Individual rows remove with their × control
  or as an arbitrary multi-selection — including pending *Preparing…* rows,
  which cancels their add — without confirmation and without deleting saved
  text/audio; the currently processing row is protected while it runs. Queue and
  Saved Audio share one selection-management control and one row-removal button:
  below two selections the pane offers its reset action, and at two or more the
  same stable button switches to Remove Selections. The Queue
  toolbar's **Reset Queue…** is the only explicit confirmed action and removes
  only queue membership, preserving Reading List inventory, saved text,
  published audio and preferences. Row removals are per-entry metadata work:
  they never toggle global running/progress state or disable unrelated controls.
  Double-clicking a queue row (or its Preview Article menu) opens the same
  Article Preview window; resolving its URL reads the saved snapshot without
  fetching and the preview window then fetches the page as it does for Articles;
  a *Preparing…* row previews from its catalog entry. The former Reading List exclusion feature is
  removed; no saved state blocks enqueue or retry, and legacy excluded/paused
  rows are retryable.
- The shared coordinator owns discovery, enqueue and pipeline writes. Pipeline
  work takes short-lived writer stores per step plus a per-library filesystem
  lease that allows exactly one speech worker — across coordinators and
  processes — while metadata writes such as pending admissions proceed
  concurrently. The UI submits commands and displays
  snapshots. This app-owned coordinator is the permanent execution owner; work
  lives and stops with the running app — Quit cancels and awaits it.

Fully automatic FIFO mode is planned as explicit opt-in within the running app's
lifetime, after recovery, retry/backoff and final-context gates. No discovery timer,
startup fetch, automatic
backlog speech, service enrollment, uploads or hosting changes are enabled here.

## Audio retention

**Settings → General → Storage → Delete audio older than** offers 12 hours, 1 day,
3 days, 1 week, 2 weeks, **1 month (default)**, 2 months, 3 months, 6 months and Never.
The choice saves automatically. Filesystem modification dates determine age;
month choices use calendar months. Cleanup runs while VoiceRelay is open: startup,
automatic rechecks, after processing, after a policy change and every 15 minutes
when idle.
If processing is active, cleanup waits until it finishes. No enrolled background
service performs deletion while the app is quit.

Only completed audio in the native library is eligible; queued/paused/failed work
and unrelated files are preserved. Captured audio folders remain authoritative,
even after selecting a different folder for new articles. Expired files leave
Saved Audio and local RSS. Article text and identities remain; readd an article
and Generate Speech to recreate expired audio using its captured settings. Never
stops future expiry; it cannot restore files already removed. Cleanup failures
appear in Settings/Queue/Saved Audio and recheck automatically after restoring
folder access (reopen the pane to prompt an immediate recheck). Model assets, source snapshots, Python/reference output and remote
feeds are not included.

Saved Audio also supports explicit removal: a row × deletes that audio file and
retires its feed enclosure after verifying the file's hash and identity; two or
more selections switch the shared pane control to Remove Selections, and zero or
one offers **Reset Saved Audio…**, which confirms and deletes every file shown at
that moment. Removal runs on the app's own work lifetime under the per-library
lease, marks durable intent before unlinking so an interrupted deletion is resumed
on the next automatic recheck, and refuses substituted, linked, unreadable or unavailable
files. Article text, queue membership, source inventory and preferences are never
touched; a removed article can be re-added and regenerated under the same identity.

Operator validation:

1. Build/run **VoiceRelay → My Mac**. In Settings → General → Storage, confirm the
   default is 1 month and the dropdown has all ten options in the requested order.
   Choose Never, quit/relaunch, and confirm it persists. Named Settings previews
   remain synthetic/inert; Canvas rendering is still operator-owned.
2. For a deletion check, use a newly generated, disposable native article. Keep
   its file intact, choose Never, and identify its UUID-named M4A in your audio
   folder. Do not use historical/reference media or a file you need to preserve.
3. In Terminal, change only that disposable file's modification date to two days
   ago (drag its M4A onto Terminal to supply the quoted absolute path):
   `touch -m -t "$(date -v-2d +%Y%m%d%H%M.%S)" "/absolute/path/to/disposable-uuid.m4a"`.
   Reopen the Saved Audio pane while Never is selected; it should remain playable.
4. Choose 1 day. The disposable audio should disappear from the folder and Saved
   Audio. Other recent audio
   should remain. Add the same article and Generate Speech; it should regenerate
   from saved text, under the same identity/captured choices, without fetching.
5. Restore your preferred policy (default 1 month). App-open scheduling, local
   feed consistency, folder permissions and real playback remain operator gates.
   Focused tests cover exact boundaries, failure recovery, queued/unrelated file
   preservation and the shared coordinator using isolated synthetic audio.

## Settings troubleshooting

Select **Settings → Troubleshooting** for compact Reading List source
diagnostics: the chosen source path or Safari Reading List, its status and any
error, with explicit **Choose Reading List…** and **Stop Loading** controls.
Source reads run automatically; there is no Refresh control. The pane has no saved-article list, typed URL or
Preview control — double-click an entry in Articles to open the Article Preview
window instead. The window fetches once with the standard bounded fetcher and
displays title, original/final URLs, issues, semantic blocks, warnings,
narration chunks and notices. It adds nothing to the queue and starts no
speech; closing the window cancels its fetch. Downloaded content is rendered
as plain text, never executable HTML.

Fetches use a fresh ephemeral URLSession without stored cookies or credentials,
a 10 MB bound, 30-second deadline and five redirects. Charset/BOM/meta declarations
are checked; otherwise UTF-8 is required. URL credentials and HTTPS → HTTP
redirects are refused. App Transport Security stays enabled. Login/consent/access
checks remain conservative heuristics; source completeness and pronunciation
still require representative listening. CLI private export remains available;
there is no app export-folder chooser.

## Managed storage and recovery

Settings saves voice/speed (Heart at 1.0× by default) and exposes one output-folder
choice: **General → Storage → Choose…** (or **Change…** once set). The folder is remembered.
This development app is not sandboxed; final signing/sandbox/bookmark permissions
remain separate gates. No config file is required.

Only opaque UUID-named M4A files go into that folder. Atomic publication briefly
uses an audio-only hidden sibling. Source/cleaned HTML, narration JSON, lossless
chunks, encoding files and tool logs use standard per-user macOS temporary storage;
completed processing scratch is removed. Each inference-helper session gets a new
private directory under the same app-owned system temporary root, removed after
its worker stops. Private Application Support `SpeechLibrary`
contains the internal SQLite schema-3 inventory, queue, settings, checkpoints,
integrity-checked source/text snapshots and local diagnostic RSS. It has no folder
chooser. Native metadata runs in SQLite WAL mode with persisted sidecars
(`-wal`/`-shm` are private durable state): read-only connections open and read
concurrently with writers, and future backups must use the SQLite backup API
rather than raw database copies. Transactional native schema-1/2 upgrades preserve episodes/snapshots;
Python/foreign/newer databases are refused. Historical workspaces stay untouched.

Saved Audio lists only finalized native files that exist and are accessible.
**Queue → Retry → Generate Speech** restores unfinished work from private
snapshots without fetching. Compatible chunks resume; purged chunks regenerate
under the same identity. Completed audio requires no scratch files. Existing
episodes retain voice/speed and destination when Settings changes. A confirmed
externally deleted file retires from Saved Audio and the local feed while its
text, identity and captured settings remain for explicit regeneration. An
unavailable volume, unreadable folder or linked path is never treated as
deletion: the row is hidden, metadata is kept, and the file reappears when the
storage returns. Tampered snapshots are refused. An explicit row × or Remove
Selections in Saved Audio is the only path that deletes audio files directly:
it verifies each file's hash and identity, retires the feed enclosure first, and
records durable intent so an interrupted removal finishes on the next automatic recheck.

## Step-by-step Xcode workflow checks

GUI, Safari access, listening, final permission context and Canvas are
operator-owned checks; compilation/tests do not certify them.

1. Quit earlier copies. Open `VoiceRelay.xcodeproj`, select **VoiceRelay → My Mac**,
   build (⌘B), then run (⌘R). No runtime reinstall/download is required.
2. Open **Settings → General**. Confirm voice, speed, audio folder and Reading List
   source controls. Use **Choose Reading List…** if needed, then open Articles;
   the chosen source syncs automatically. Existing inventory and saved speech
   should remain intact.
3. Select two new readable entries using ⌘-click. Selection should highlight them
   without opening/loading a review. Click **Add to Queue (2)**. Both should
   briefly show a *Preparing…* pending row, then show a Ready checkmark in Queue,
   in displayed list order, with no new audio or speech. Double-click an entry
   and its Article Preview window should load title, blocks and chunks; closing
   the window cancels its fetch.
4. Add one of those entries again. Expect one existing queue item, preserving its
   original choices and position. Change voice/speed and optionally audio folder,
   then add a different article; only the new article should capture those changes.
5. Quit/relaunch. Queued entries should persist without processing. Click
   **Generate Speech** in the toolbar or status menu, then listen via **Saved
   Audio → Show in Finder** (Quick Look with Space, or Finder double-click).
   Verify FIFO completion, source completeness, captured voice/speed/destination.
   Watch the menu or Queue progress: article completion should advance from 0/2
   to 1/2 to 2/2, and the current-article label from Article 1 of 2 to Article 2
   of 2. Finishing audio or checking saved audio must not report 100% before
   validation completes. Each verified completion leaves Queue and remains in
   Saved Audio. After **Stop Generating** the interrupted row is already Ready;
   **Generate Speech** starts a fresh batch of remaining waiting work.
6. Open **Settings → Troubleshooting**. Confirm the Reading List source path,
   status line and Choose control; the pane has no saved-article list,
   URL field or Preview button. Double-click an entry in Articles to open the
   Article Preview window; it should show semantic blocks and narration. Its
   Close button dismisses it. These actions must not enqueue or synthesize
   anything.
7. If a selected source fails or presents consent/login, the pending row records
   a per-entry issue while other selected entries still add. Diagnose it by
   double-clicking its entry in Articles to open Article Preview. **Stop
   Generating** does not cancel pending additions; while entries are being
   added, remove a pending row with its × or as a multi-selection to cancel
   its add, and earlier saved queue items must remain. Preview fetches stop
   when their window closes. Double-click a committed queue row to reopen the
   saved article in Article Preview; its URL resolves from the saved snapshot
   and the preview fetches it like Articles rows.
8. Add a longer article, start, then **Stop**. Confirm the interrupted row is
   Ready and **Generate Speech** works without Retry. Separately quit during
   processing and relaunch: unfinished work requires **Queue → Retry → Generate
   Speech**. Queue removal preserves saved text and audio. In Saved Audio,
   removing a row with × deletes its file and drops its feed enclosure while
   the article text stays; two or more selections switch the pane control to
   Remove Selections, and zero or one shows **Reset Saved Audio…**, which asks
   for confirmation before deleting every shown file. Optional removable
   volume testing: eject while idle, expect no substitute on failure, reconnect
   and retry. Abrupt Xcode Stop/relaunch recovery remains a separate operator gate.
9. Check named inert **Articles — inert multi-selection**, RelayMenu, WorkspaceView,
   Settings, Troubleshooting, Queue and Article Preview previews in Canvas. Menu
   and toolbar run controls use the queue; there is no sample-speech control.
   Inert preview construction must fetch nothing. Continue
   tracking beta layout/linkd messages separately from audio success.
10. From the status menu, choose **Articles** and **Settings…** in
    turn. The native menu dismisses itself and shows/focuses its window. Reopen
    the menu after each action; it must remain usable. With any standalone window
    open, expect a Dock icon and a VoiceRelay entry in ⌘-Tab. Open two windows,
    close one, and confirm the entry remains. Minimize the remaining window and
    confirm VoiceRelay remains switchable. Close the last standalone window;
    the Dock icon should disappear and the menu-bar item should remain usable.
11. Check that **Stop Generating** is disabled while idle. Start generation, stop
    it, and confirm the interrupted row returns to Ready and **Generate Speech**
    works. If a storage/read error recurs, capture its entire message and
    note the article/stage. Restore the originally captured audio folder/volume
    before retrying; changing the folder for new articles does not relocate saved
    episodes. Do not delete real audio or article data to force this test.

The dormant agent prototype remains bundled as inactive reference material;
the app owns processing for its entire lifetime and nothing registers or
launches the prototype. AGENT_PROTOCOL.md is now a superseded-design record.

For synthetic discovery without protected files, choose
`Fixtures/reading-list.synthetic.plist` and it syncs automatically: expect two
entries and zero skips. Its `.invalid` URLs cannot provide live article content.

## Optional CLI and focused checks

Run from the project root. The synthetic discovery check needs no Safari access:

```sh
cd /path/to/VoiceRelay
swift build
native_bin="$(swift build --show-bin-path)"
"$native_bin/voicerelay" reading-list --plist "$PWD/Fixtures/reading-list.synthetic.plist"
swift test --filter SourceReviewTests
```

Expected discovery output: two entries, zero skipped; no titles/URLs printed.
`reading-list --plist /absolute/path/to/Bookmarks.plist` is the explicit protected
read under the launching CLI/Terminal context. It is separate from the app's own
permission context. `doctor` remains read-only and does not read Reading List data.

To fetch/export exactly one URL, choose the source yourself and substitute its
HTTPS URL below. The command produces no audio/feed or live-state mutation:

```sh
"$native_bin/voicerelay" review-url --url 'https://example.com/selected-article' \
  --directory "$PWD/var/source-review"
```

An optional explicit `--config /absolute/config.toml` preserves imported limits
and adds destination-overlap protection. No local `config.toml` is imported unless `--config` is supplied. A review-needed outcome is a completed diagnostic
export, not successful article acceptance. Operational fetch/export failure
returns exit 1 with a fixed diagnostic.

## Caption, encoding and footnote policy

Cleaned HTML exports are complete documents with an explicit UTF-8 charset.
Inline media and embedded content are removed from this review artifact. The
immutable source snapshot retains original image markup, URLs and alt/caption
material. Explicit caption classes are converted to caption elements before
extraction; adjacent identical caption blocks are retained once. Repeated body
paragraphs and captions separated by other content are preserved. Captions are
read once as authored text; no AI image interpretation runs.
Header publication-time/permalink markup is omitted from the derived review to
avoid metadata and URL readouts; it remains in the original snapshot.

Semantic blocks preserve original reference-marker text. Optional
`narrationText`, `footnoteReferences` and `footnoteID` fields distinguish spoken
wording and target/provenance from that text; old artifacts without these fields
still decode. Recognized local footnote/citation links (numbered or symbol
markers, explicit roles/relations/classes, and common target IDs) omit their
marker/backlink from speech. At the first reference, narration inserts the
resolved note's paragraphs after the referring block:

```text
Referring paragraph without its reference marker.
Footnote:
First footnote paragraph.
Second footnote paragraph.
End Footnote
Next article paragraph.
```

Repeated references do not repeat the note. Definitions discarded by the
extractor are recovered from the private source for referenced targets; unrelated
source-page notes are not imported. Unreferenced notes retained by the extractor
remain at the end with a notice. Unresolved marked references produce a notice,
with no invented note text. Ordinary numbers, mathematical superscripts and
unmarked citations are not guessed or stripped. Decorative symbol separators
are retained semantically and omitted from speech.

Extraction/narration version fingerprints have changed. Existing exported
snapshots remain unchanged; run the explicit diagnostic CLI export again to create a new export.
Published fixture checkpoints continue to use their validated saved versions;
they are not re-extracted or regenerated merely because a version changed.
Use a new empty fixture folder to test the current policy. Browser rendering
and listening still need operator validation.

## Remaining acceptance gates

The focused suite exercises synthetic XML/binary files, URL/delegate redirect
policy, charset handling, in-process URLSession responses, bounds/deadlines/
cancellation, semantic provenance, failed-page outcomes and private exports.
It does not establish live network redirect/auth/TLS behavior, actual Safari
hierarchy/permissions, Xcode bundle/Canvas behavior or article quality.

Automatic discovery/backoff, representative real-source corpus,
reviewed-article Kokoro processing/listening, signed app relocation, final app
permissions and delivery remain future work. The existing explicit Kokoro speech
fixture has its own [operator guide and listening gates](KOKORO_PROVIDER.md).
No model inference, helper enrollment, live state adoption or upload occurs as
a side effect of opening Articles or building the project.
