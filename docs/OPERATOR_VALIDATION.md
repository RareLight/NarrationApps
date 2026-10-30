# Consolidated app validation checklist

Current instructions reviewed October 21, 2026; title-recovery cases added
October 23, 2026. Prior operator results retain
their original dates. This is the single current operator checklist for Libro
and VoiceRelay. Earlier UI, beta, Settings, pronunciation and longform handoffs
are consolidated here; their implementation/build evidence remains in the
[implementation status](IMPLEMENTATION_STATUS.md) and
[longform record](KOKORO_LONGFORM_IMPLEMENTATION.md).

The operator confirmed both apps build and run on October 16, 2026. Basic
relocation/build/launch smoke is accepted; individual feature, quality, data and
live-service cases below remain unconfirmed unless explicitly recorded elsewhere.

## Before starting

Select the app build and relevant checklist IDs before testing. A documentation
review does not require repeating model downloads, live Publishing or private-
document/listening checks. Use an authorized disposable setup for those cases.

Open `NarrationApps.xcworkspace` from the monorepo root. The
[layout/archival gate](REPOSITORY_LAYOUT.md#migration-validation-and-archival-gate)
records the earlier relocation; do not restore nested repositories or require the
archived originals to test current source.

Earlier feature validation used synthetic generated fixtures at
`.build/cover-navigation/fixtures` (EPUB notes/appendix/bibliography/duplicate
headings, Markdown headings and covers). Those generated outputs were not migrated;
maintained Swift fixtures/tests remain. Use equivalent disposable documents and
artwork for the operator checks below. Actual-document/player acceptance remains
separate from automated fixture tests.

- Quit older copies of each app. Current October 28 model-layout/cache candidates
  are `.build/WorkspaceDerivedData/Build/Products/Release/Libro.app` and
  `.build/WorkspaceDerivedData/Build/Products/Release/VoiceRelay.app`, with parallel
  Debug products. Both configurations and four bundle audits passed in
  `.local/validation/release-DBD0321A-79CD-4A41-8565-751307F17B1D/`; these ad-hoc
  products have not replaced the running apps. Archive checks were omitted for
  this final snapshot; create normal release archives manually when needed.
  GUI/listening/account acceptance remains open.
  The earlier October 28 multi-model engineering candidates
  are in `.local/validation/release-CF376C4F-5242-41A5-8105-B4247F18C718/`:
  `Libro.xcarchive/Products/Applications/Libro.app` and
  `VoiceRelay.xcarchive/Products/Applications/VoiceRelay.app`. Both archives and
  Debug/Release workspace builds passed bundle audits for the working tree based
  on `c10135f`; they are ad-hoc signed and have not been installed or launched.
  GUI/listening/account acceptance is open. These ignored local candidates may be
  absent on another machine; build from maintained source using the development
  gates rather than copying caches.
  The earlier October 27 Libro review-fix engineering
  products are `.build/LibroReviewFixes-20261027/Build/Products/Release/Libro.app`
  and `.build/LibroReviewFixes-20261027/Build/Products/Release/VoiceRelay.app`.
  Debug products are in the parallel `Debug` folder. Both configurations passed
  bundle/signature/resource/offline Metal checks; GUI, listening and account
  acceptance are unperformed. See the [fix record](LIBRO_REVIEW_FIX_PLAN.md).
  The earlier October 23 title-recovery ad-hoc products
  are `.build/TitleRecoveryValidation-20261023/Build/Products/Release/Libro.app` and
  `.build/TitleRecoveryValidation-20261023/Build/Products/Release/VoiceRelay.app`, relative to the
  monorepo root. Local generated products may be absent on another machine.
  Select an operator candidate explicitly; preserve any earlier bundle already
  under active review. See the [title-recovery status](IMPLEMENTATION_STATUS.md#voicerelay-article-title-recovery)
  and earlier [migration record](MONOREPO_MIGRATION.md#validation) for evidence scope.
  Rebuild/re-archive changed source before
  attributing results to it. Use the combined workspace for both apps.
- Use a separate output folder and disposable test articles. Keep existing models,
  finished audio and the live library intact. For fresh-install tests, use a
  separate macOS user/test installation rather than deleting working caches.
- Use your normal team/profile-signed VoiceRelay build for existing Keychain
  credentials and live Publishing tests; the ad-hoc copies do not establish
  account/entitlement acceptance. Installation/relocation and restore tests are
  conditional; mark N/A until a suitable test user/library is available.
- Dated engineering records include passed suites, builds, archives, signatures,
  offline workers and arbitration at their recorded revisions. The earlier A/B
  listening decision is complete; you do not need to
  repeat it. New Kokoro settings use Heart at 1.0× with the accepted pause profile;
  existing saved speeds and admitted jobs keep their values.
- New Kokoro spoken forms expand explicit kilograms, Celsius/Fahrenheit and
  AM/PM times. Delivery A matched listening, including letter A, is accepted;
  use B05 for remaining app-preview checks. Contextual `lead`/`read`
  and unsupported/ambiguous forms remain limitations. See the
  [normalization record](TEXT_NORMALIZATION_RESEARCH.md).

## Libro

- [ ] **L01 — Launch and setup.** Existing models are recognized. In a fresh test
  user, try Not Now, installation, cancellation/retry and successful dismissal of
  setup. Compare the identical Model Setup layout/actions with VoiceRelay at normal and 200% text size;
  also try Choose Custom Model Folder. Download beside the main picker uses the shared Hugging Face cache by default. In Models, verify the disk-size list, folder override/reset, and confirmed deletion while idle; an active session in either app blocks deletion. Automatic speech-setup validation works offline after
  installation. Select a British voice and install its regional resources if asked.
- [ ] **L02 — Settings and appearance.** Visit General, Document, Models, Pronunciation and
  Troubleshooting. Test text size at 80%, 100% and 200%, ⌘+/⌘−/⌘0, minimum window
  sizes, light/dark, reduced motion/transparency, contrast, keyboard focus and
  VoiceOver. Help, long errors and controls remain readable. Change model, Kokoro
  voice and speed, quit/relaunch, and verify all three choices persist, including
  switching back from Soprano.
- [ ] **L03 — Voice samples.** Try every presented voice, including Soprano.
  Include all nine Qwen presets, eight Orpheus presets and Chatterbox default. Check that Models settings does not repeat the main selection menus.
  Both apps use the same compact model row: Download arrow when missing and
  adjacent ⓘ for description/meters, with no file size or trash action.
  Downloaded models shows name, size and confirmed Delete in compact fixed columns
  under the folder controls; verify different names/sizes and imported rows align.
  Confirm Libro's idle status cell stays blank while progress/issues still appear.
  At the same window/text size, switch every model: Model and Voice menus stay
  aligned at the same positions and widths, optional fields stay below them, and
  the section grows/shrinks to the visible controls without reserved blank space.
  Controls follow Model → Voice → model options → Play Sample, with compact,
  consistent gaps and a shared left edge.
  Speed's value/arrows sit beside its label; Sample follows options without a blank
  gap or a separate right-hand column. Libro's output control stays top-aligned. Repeat in
  VoiceRelay's Voice Model pane, with Chatterbox references and at large text sizes.
  Confirm deletion, verify the arrow returns, and verify blocked/failed deletion
  keeps the cached model. Imported folders remain read-only. Switch models/folders
  during a storage refresh; Download follows the selection and inventory deletion
  stays tied to its confirmed folder/model. Check narrow windows, large text and VoiceOver. Qwen
  native-language notes are distinct from narration language. Non-English and
  imported-reference selections offer live previews after installation; check
  cancellation and missing-model guidance. Changing language or delivery settings
  during playback stops the previous sample/preview. Import an authorized disposable WAV
  into Chatterbox and confirm the same profile can be selected in VoiceRelay.
  Play/Stop and switching voices work without installed models; finished-audio
  playback does not overlap. The common phrase starts “Hello, I can narrate…”
  and plays at recorded 1.0×, independently of generation speed/overrides.
- [ ] **L04 — Pronunciation.** Add, edit and remove a temporary override such as
  `SQLite` → `sequel lite`; use Play with the selected voice/speed.
  Check that the centered dictionary list and editing buttons occupy 75% of the
  window width and resize with the window, including at large text sizes. Narrate text
  containing both `SQLite` and `SQLites`: only the complete key should change,
  while original source prose stays intact. Check busy/missing-model guidance.
- [ ] **L05 — Import and queue.** Use Open and Finder drag/drop for text, Markdown,
  RTF, PDFs and DRM-free EPUBs, including folders. Check duplicate imports, long names, editable
  output names, selection/removal and keyboard shortcuts without disrupting typing.
  Re-drop a saved document: its row must become queued again. Adding a different
  source must leave old finished rows finished and active jobs unchanged.
  Cancel or Clear Queue while a drop is still locating files: late provider replies
  must not restore rows. Replace an import during scanning and quit during intake;
  old work must settle without overlapping replacement scans or reappearing later.
  Drag single and noncontiguous selected rows to the beginning, middle and end;
  verify native insertion markers and execution order. Import another file and
  check the chosen order remains. During processing, reorder waiting items within
  the active batch; current/completed rows and next-batch membership stay fixed.
- [ ] **L06 — PDF/OCR quality.** Compare selectable-text, scanned, mixed and
  multi-column PDFs, including contents pages with dotted leaders, with their
  previews: reading order, paragraphs, lists, notes,
  beginnings/endings, and visible table/code omissions. An unusable PDF should
  fail clearly without discarding other documents. Footnotes follow the preview's policy.
- [ ] **L07 — Preparation progress.** On a longer mixed PDF, check file/structure,
  page/native-layout/OCR counters and the separate image-review pass when available. Pronunciation
  preparation reports passages before the final speech count. Cancel during a
  pass and queue two PDFs: stale updates must not overwrite cancellation or the next job.
- [ ] **L08 — Images and captions.** Test authored descriptions, repeated credits,
  distinct captions and an image lacking a description. Duplicates are suppressed
  without deleting prose. Apple Intelligence descriptions are brief and marked
  generated; disabling/unavailable Intelligence retains authored text and OCR.
- [ ] **L09 — Narration and exports.** Generate with Heart at 1.0×, Michael, Emma
  and Soprano. Listen for complete ordered speech, endings, clause/section/note
  pauses, no clipping/repetition and natural levels/dynamics. Play WAV, AAC and
  available MP3 exports inside/outside Libro. Existing recordings remain unchanged.
- [ ] **L10 — Original freeze reproduction.** Import your original 12-page PDF
  and 600-word Markdown together and generate. Watch Libro and LibroSpeechWorker
  separately in Activity Monitor; note peaks, memory pressure and behavior after
  completion/Stop. Repeat a batch to check for continuing memory growth. Synthetic
  measurements are reference evidence, not a pass for these private documents.
- [ ] **L11 — Current versus next batch.** During generation change Next Batch
  Settings and add another document. The active batch retains its voice/speed,
  output format and destination; pending changes apply only to subsequent work.
- [ ] **L12 — Stop, Quit and recovery.** Stop during preparation and speech, then
  run a fresh batch successfully. Close/reopen the window during work and test the
  Quit choices. Cancellation must settle, Quit must stop owned helpers, and finished
  files must survive. Queue Again/Queue Unfinished must not immediately start work.
  Check the circular Start/Stop, Pause/Resume and Skip controls and menu equivalents.
  Pause waits for the current operation, then resumes the same partial recording;
  Stop keeps unfinished items queued. Confirm Skip during analysis, narration and
  saving; the next item proceeds, existing outputs survive, and a stale confirmation
  must never skip the next item. Skip while paused leaves the next item paused.
  Check narrow windows, larger text, keyboard focus and accessibility labels.
  Cover editing stays below the divider, destination controls stay adjacent, and
  readiness/counts/activity occupy the bottom bar with full messages in Details.
- [ ] **L13 — File errors and replacement.** Test an empty text file, a locked or
  unreadable PDF, duplicate output names and an unavailable destination. Recovery
  messages/Details are actionable; cancelling replacement or a failed job preserves
  existing complete output. Re-selecting a destination restores normal generation.
  Queue files whose audio already exists: enqueue succeeds. Start Queue offers
  Overwrite Existing, Skip Existing and Cancel. Check a mixed batch and an all-existing
  batch; skipped rows are visible, Queue Again works, and Cancel preserves the queue.
  If a previously failed item is skipped, Queue Unfinished must queue it again;
  changing an eligible skipped text item's encoding must also allow reprocessing.
  Try an output folder inside a selected unpacked EPUB: it must be rejected,
  including a symlink alias. A new file placed at an unapproved output path during
  generation must survive; reviewing a later batch can approve its replacement.
- [ ] **L14 — Alerts and diagnostics.** Check completion alerts with permission
  allowed/denied. Try Check Embedded Helper and log Copy/Open/Reveal/Clear if wanted;
  controls explain unavailable/busy states. Keep diagnostic text/paths private.

- [ ] **L15 — Legacy text encodings.** Import older Windows-1252 and Mac Roman
  text/Markdown. Preview smart quotes, accents and paragraph contents; automatic
  detection may be ambiguous. Right-click → Text Encoding, choose the actual code
  page, then preview/generate again. Rescanning the same imported row preserves its
  choice; active batches cannot change encoding. Binary/damaged Unicode fails
  clearly, original files stay unchanged, and completed audio survives Queue Again.
- [ ] **L16 — EPUB books.** Import DRM-free EPUB 2 and EPUB 3 books through Open,
  folders and Finder/drop, including an unpacked `.epub` folder: it must enter as one book, show its cover
  when available, and preview/generate without importing its individual resources.
  Compare chapter order, beginnings/endings, headings,
  cross-chapter notes and repeated local note IDs against the book. Check section
  progress, authored ALT, duplicate images, optional local descriptions and Stop.
  External resources must not be fetched. A protected/malformed/unsupported book
  fails clearly without reporting partial narration as complete. SVG/fixed-layout
  text needs reading-order review; image-only page OCR/media overlays are not added.

- [ ] **L17 — Export covers.** Select one document, choose the portrait fixture or
  your JPEG/PNG, and export MP3, M4A and M4B. Confirm artwork, duration and seeking
  in your players; audio levels must remain unchanged. Test Replace/Remove,
  relaunch, selecting a different document, and explicit multi-selection. WAV
  keeps the choice but explains it is not embedded. Choose an EPUB's Use Book
  Cover; missing/unsupported cover metadata offers a clear message. Bad images,
  cancellation and failed export preserve previous output and original images.
  On the automatic-cover candidate, also import a PDF with a designed first page,
  a metadata-marked EPUB and an EPUB whose cover image is embedded on its opening
  page. Check automatic thumbnails preserve the full rectangular artwork/title.
  Replace manually, add/rescan inputs, and confirm that choice wins. Remove and
  re-add the document: no automatic re-selection until Use Book Cover is chosen.
  Blank/locked/unsupported artwork must not prevent other documents importing.
  Document rows should show a small uncropped cover beside the title whenever
  artwork is available, including with WAV selected. Check automatic detection,
  manual Replace/Remove and scrolling/reordering; uncovered or unavailable art
  should show the document symbol, never another row's previous cover.
- [ ] **L18 — Contents and source.** Preview the synthetic EPUB/Markdown and an
  authored-bookmark PDF. Contents should navigate the correct Original Source
  section/page, retain nesting and explain page precision. Switch back to Narration;
  chapter order remains unchanged. No inferred plaintext chapters or audio chapter
  markers are promised. Compare the adjacent duplicate heading with its visible
  omission and retained original source.
- [ ] **L19 — Document settings.** In Settings → Document (between General and
  Models), compare Read with the text, Read at the end and Do not read for
  Footnotes. Immediately below are Strip inline citations and
  Strip endnote citations, both initially off. Test each independently and together:
  author–year/verified numbered references and bibliographies/citation-only notes
  should be skipped, while explanatory notes, parentheses, dates, quantities and
  unlinked numbers remain. Check saved choices and newly captured batches.
  Turn Read appendices and extra sections off/on. Check
  short hover help and the changing document/narration examples for each control,
  including PDF word joins and image descriptions. Examples start collapsed behind
  Show example; clicking or keyboard activation expands the preview and rotates
  the trailing chevron 90° clockwise. Check collapse, independent disclosures,
  VoiceOver expanded/collapsed state and reduced-motion behavior. Examples remain
  readable at 80–200% text sizes and do not start document analysis or speech/model work.
  General retains appearance/alerts; Document has no pronunciation shortcut.
  Preview and generate a new batch: the note/appendix treatment should agree,
  bibliography/unclassified prose stay present, and omissions are explained.
  Changes must not alter an active batch or finished output. Listen for intact
  body text, note boundaries and the accepted unchanged vocal pacing.

- [ ] **L20 — Responsive PDF narration previews.** Open a long digital PDF with
  printed word wraps and a mixed/scanned PDF. The row should say Analyzing text;
  narration should appear after the first rounded-up 5% (at most five pages),
  before the rest of the book or optional image descriptions finish. Check visible
  partial/page-count status, growing narration and Original Source, and final
  Contents/navigation. The segmented label must not wrap vertically; narration
  must retain scrolling space with many analysis notes expanded or collapsed.
  Resize at small/large text sizes. Review possible margin/page-join changes while
  the prefix grows. Done/Escape/dismissal must cancel background work without
  reopening the sheet or overwriting a subsequent document. Test cancellation and
  a later failure: partial content must not be labeled complete. Compare the final
  preview with normal narration for both engines; generation and existing audio
  must remain unchanged. OCR and file-provider opening can still delay the first
  readable prefix. Report actual-book timing and layout separately from fixtures.

## VoiceRelay

- [ ] **V01 — Launch and setup.** Existing speech assets are recognized. In a
  fresh test user, check Not Now, explicit Install Model, custom-folder selection with automatic validation, cancellation/retry
  and successful dismissal. Automatic validation works offline; startup/checking must
  not silently download. Check the British voice resource-install path when needed.
- [ ] **V02 — Settings and presentation.** Visit General, Voice Model, Pronunciation,
  Publishing and Troubleshooting. Confirm model/voice selectors, download/delete, size, details/meters,
  Play Sample, downloaded-model storage and setup checks are in Voice Model and
  absent from Articles. Check 80%/100%/200%, ⌘+/⌘−/⌘0, small/large windows, keyboard,
  VoiceOver and appearance/accessibility options. Open/close Settings and Help during
  work: they remain responsive and Help performs no processing or network operation.
  Left-click and right-click the waveform menu-bar icon: both open the same popover,
  immediately without a spring animation, including before any ordinary window
  opens after login. Check repeated toggling,
  Escape and outside-click dismissal, Sync Now progress, and Articles/Server Audio/
  Settings opening and focusing correctly after dismissing the menu.
  At 80%/100%/200%, check compact command width, wrapped long status/progress text
  and no width jump during Sync. Each opening starts without a focus outline;
  Tab/Shift-Tab reveal focus and traverse enabled commands, with Space activating
  the focused command. Hover feedback and VoiceOver remain available.
  Check the extra horizontal room and larger icon without clipping. Copy Podcast
  URL copies the configured public feed address and dismisses the popover; it is
  disabled before configuration. General's citation toggles share the other
  narration controls' grouping.
- [ ] **V03 — Voices and samples.** Check saved voice/speed preferences, new Heart
  1.0× defaults, the shared voice names and 0.05× speed steps. Try every presented
  sample, Stop and switching voices while idle/busy. The new common phrase is
  bundled and plays at 1.0× without models or pronunciation overrides.
  Repeat with Qwen, Chatterbox and Orpheus; all presets and shared meters must
  match Libro. Switch models and relaunch: each model restores its own controls.
  New selections apply to later articles; retry an existing queued article after
  changing Settings and confirm its captured narrator remains. Check reference
  import/live preview and a restored job whose reference clip is missing; it
  must fail clearly until the original clip is reimported. References are excluded
  from ordinary library backups. Keep production libraries out of this test.
- [ ] **V04 — Pronunciation.** Add/edit/remove a temporary spelling override and
  use Play. Confirm newly prepared narration uses it once, source prose is retained,
  and preview cancellation/busy/missing-model states recover normally.
- [ ] **V05 — Reading List and permissions.** Check launch, manual and periodic
  refresh with the real selected Safari source. Saved dates/original sites remain
  correct and VoiceRelay does not edit Safari. An unreadable source retains known
  entries and does not admit stale ones. Source choice persists across relaunch.
- [ ] **V06 — Queue, selection and filters.** Add/remove disposable items; check
  All Articles versus Queue, saved-date versus processing order, search, website/date
  filters, counts and keyboard actions. Hidden selections are never removal targets.
  Queue removal must not delete the Safari source or published recording.
  For duplicate saves, compare a newer short/paywall copy with older full text,
  then two equal full copies with different save dates. Only the fuller/newer
  selection generates; the other row stays gray with Inactive duplicate. Refresh,
  restart, clear Queue and remove test audio: unchanged handled copies must not
  recreate audio. Add a genuinely new duplicate save with a different voice;
  confirm the new narration/feed before the older owned audio/transcript is removed.
  Interrupt upload/feed/cleanup and verify safe recovery without losing the old
  server copy prematurely.
- [ ] **V07 — Article extraction.** Preview short/long articles from different
  sites, including a PDF URL, a blocked/failed page and an archived copy if enabled.
  Verify completeness, title/source, saved date, reading order and provenance.
  Retained text works offline; a teaser/challenge page is not a successful article.
- [ ] **V08 — OCR and image narration.** Check scanned/mixed PDFs, authored ALT,
  distinct captions, duplicate credits and missing descriptions. Toggle Apple
  Intelligence descriptions and try unavailability; OCR/authored content survives.
  New preferences affect newly added articles, not finished audio/retained text.
  Remove a Preparing test row or Quit during a scan: late results must not re-admit it.
- [ ] **V09 — Normal unattended work.** Add disposable articles and let discovery,
  preparation, speech and delivery run with windows closed. Listen to complete
  narration at the captured voice/speed; no artificial leveling or missing endings.
  Progress distinguishes preparation, speech, finalization and publishing; future
  unknown queue totals must not masquerade as a measured overall percentage.
- [ ] **V10 — Manual Sync and interruption.** Sync Now processes eligible work
  even with automation off, without changing preferences. Repeated clicks coalesce.
  Test Stop and Quit during speech/finalization, then relaunch/resume/retry: no
  duplicate episodes, automatic failed-row replay, or replacement of completed audio.
- [ ] **V11 — Publishing and credentials (live).** With normal signing, test
  an existing protected credential: background publishing must not prompt; follow
  the re-save instruction in Publishing once. Cancelling Save preserves the old
  credential. Save again, quit/relaunch, reboot/sign in and lock the screen: delivery
  should read the saved password without per-session authorization. Test Connection
  remains responsive and uses sanitized errors; signed-identity changes are a separate
  Keychain acceptance check. Never test existing credentials with an ad-hoc artifact.
  A readable-folder result alone must not claim successful upload/public playback.
- [ ] **V12 — Publish and listen (live).** Publish one disposable article. Check
  media verification, feed membership, Uploads clearing only after confirmation,
  then Server Audio and podcast-player playback (for example Overcast), title,
  original saved date, artwork when present and complete enclosure audio. Repeat
  Sync/relaunch: confirmed episodes are not re-synthesized or re-uploaded.
- [ ] **V13 — Delivery failure/retry (live).** Disconnect/reconnect during a test
  upload or use an unavailable test destination. Pending/failed state survives
  relaunch, healthy items continue, retry succeeds once and progress does not call
  100% sent “published.” Filters/counts and per-item actions stay current.
- [ ] **V14 — Removal and destination changes (disposable test data only).**
  Distinguish Queue removal, Safari-source removal, local upload-copy discard and
  Server Audio removal. Published copies survive source/queue/local-only removal;
  server deletion retires feed membership first and stays pending until confirmed.
  Click Server Audio × repeatedly on different rows: each accepted row disappears
  immediately without resizing/animating first, while other actions and the
  remaining selection stay usable. The lower status bar shows cleanup progress.
  A slow server/polling refresh must not reinsert active deletions; local, feed or
  server-delete failure restores only the affected pending items for retry.
  Changing to a test destination preserves old-host copies and avoids old-host deletes.
- [ ] **V15 — Backup/restore (dedicated test library).** Back up while idle, then
  restore through Troubleshooting and review Articles/Queue/Server Audio. Identity,
  saved dates and retained text survive; credentials/preferences remain separate.
  Sync/automation/delivery stay gated until Finish Library Review. Preserve the
  backup and previous library; do not experiment on your only live copy. No CLI is required.
- [ ] **V16 — Diagnostics.** Try sanitized session-log Copy/Clear while idle;
  messages and busy states are clear. Source/setup/publishing failures route to the
  relevant Settings pane. Keep real URLs, credentials and source text out of reports.

- [ ] **V17 — Podcast Cover.** With no previous cover choice, confirm the bundled
  icon-derived cover appears in Publishing. Replace it and relaunch: the custom
  cover stays selected. Remove it and relaunch: it stays removed. Then choose the
  square fixture or an opaque JPEG/PNG of at least 1400 pixels per side. Reject the transparent fixture
  and portrait image clearly. Test Replace/Remove/relaunch. On a disposable live
  destination, confirm show-cover upload precedes RSS, podcast display refreshes,
  and episode pictures remain article-specific. Failed cover upload preserves
  the previous feed and retries. Cover-only edits must not regenerate/re-upload
  episode audio or change GUIDs/dates. Destination changes preserve old files.
  Publishing configuration/art remains separate from library backup/restore.
- [ ] **V18 — Article Contents.** Open an article with real headings and a PDF
  with authored bookmarks. Contents navigates the corresponding semantic source
  block/page, while narration order stays intact. Missing destinations must not
  open an unrelated section. Check the retained source and visible duplicate-
  heading notices against the narration preview.
- [ ] **V19 — Captured narration choices.** In General → Document Narration,
  change Footnotes, citation choices and Read appendices and extra sections, then add new articles with marked
  notes/appendices. Confirm preview and generated content agree, bibliography and
  unclassified text remain, and queued articles keep their captured settings
  when preferences change. Already published audio remains unchanged.

- [ ] **V20 — Login startup.** On a normal signed installed app, confirm
  fresh configurations request startup once. The control appears only in General Settings,
  never Model Setup. Existing configurations retain their OS setting;
  follow any Login Items approval prompt. Sign out/in: VoiceRelay starts in the menu
  bar with no restored Articles/Settings/Preview/Help/setup windows, and configured automation
  resumes. Quit stops it until manually opened or the next login. Toggle off and
  sign out/in: it stays closed. Change consent in System Settings and reopen Settings:
  actual OS state/approval is reflected without silent re-registration. Repeat with
  speech setup incomplete; a login launch must not open the setup window.

- [ ] **V21 — Article titles.** Add disposable PDFs whose metadata repeats their
  original or redirected filename, including differences in case, separators and
  `.pdf`. Confirm a useful Reading List title or clear printed headline is used;
  ambiguous layouts retain a fallback. With Article titles generation enabled in
  General, review actual on-device title quality and the generated-title label;
  with Apple Intelligence unavailable, preparation must still complete. Check
  All Articles, Queue, the saved preview and spoken introduction agree. Stop
  processing and use Edit Title before the first speech attempt; confirm the
  correction survives refresh/relaunch and appears in newly generated audio/RSS.
  Started work and published recordings must keep their titles. Tall scanned
  paragraphs must not be mistaken for large headline type. Safari stays unchanged.

- [ ] **V22 — Timed podcast transcripts.** In General → Episode transcripts,
  confirm Publish timed transcripts defaults on and persists across relaunch.
  Queue one article, turn the option off and queue another: only the first gains
  a transcript. Verify the host serves `.vtt` as `text/vtt` with the episode's
  access protections. In a compatible player, check segment text, pauses, live
  scrolling and tap-to-seek against actual audio. Check your installed Overcast
  version separately (reported App Store 2026.10.1, build 1182);
  supplied-transcript support is unconfirmed. Test
  a failed sidecar upload and Sync Now retry without new speech. Old recordings
  and source documents must remain unchanged. Word-level timing is not provided.

## Both apps together

- [ ] **B01 — Shared dictionary.** In both apps, check that matching/preservation
  prose is hidden behind the Pronunciation ⓘ control and opens with keyboard or
  mouse. Check the centered list's gray rounded background, row selection, scrolling
  and keyboard focus in light/dark appearance. Save a pronunciation change in one
  app and confirm it appears in the other.
  Try competing edits: Reload/conflict handling
  must preserve saved work. Edit during speech: current work retains its snapshot,
  and the next batch/article adopts the change. Restore temporary test entries afterward.
- [ ] **B02 — Libro priority.** Start a long VoiceRelay job, then generate in
  Libro. VoiceRelay finishes its current GPU operation, waits, and resumes in order
  after Libro finishes. Opening an idle Libro window must not block VoiceRelay.
- [ ] **B03 — Waiting and cancellation.** Repeat while stopping/quitting Libro,
  and while cancelling waiting VoiceRelay work. Waiting work must resume or cancel
  cleanly without lost completed audio. Check preview/OCR/image work while the other
  app narrates. Observe each app/helper separately; idle cached models may remain resident.
- [ ] **B04 — Shared controls, independent preferences.** Compare overlapping
  labels, help, errors, voice/sample controls and text sizing. Existing app-specific
  preferences remain intact. Preview/sample playback should stop conflicting playback within each app.

- [ ] **B05 — New spoken forms (both apps).** In Libro, import the synthetic
  a disposable text document with the examples below. If retained locally, the
  archived `.build/text-processing/delivery-a/listening/` fixtures can also be used.
  In VoiceRelay, preview a disposable authorized article containing equivalent
  quantities/times. The operator accepted the matched listening and
  `.build/text-processing/letter-a/listening/index.html` (archived corrected letter A clips).
  The app preview checks below remain unreported. “Package A” and
  “Plan A” should say the letter name (“ay”); “A car” / “a book” remain articles.
  Compare original source and preview: `2.4 kg` → `2.4 kilograms`,
  `1kg` → `1 kilogram`, `18°C` → `18 degrees Celsius`, `−4 °F` →
  `minus 4 degrees Fahrenheit`, `9:30 am` → `9 30 a.m.`, `9:05 pm` →
  `9 oh 5 p.m.`, `12:00 pm` → `12 p.m.`. Check change notices, US/British voice
  context and a temporary user override (which must win). Fresh markup previews
  capture inline-code protection; older retained markup without this metadata
  may abstain with a notice. URLs/code/equations
  and Soprano should retain their existing behavior. Matched Heart/Michael/Emma
  listening at 1.0× is accepted; check app-generated equivalents: numbers, sign,
  unit, AM/PM and sentence cadence must be clear, without level changes. Restore
  temporary overrides afterward. Delivery B is already implemented; this item
  does not restart its historical approval gate.

- [ ] **B06 — Paragraph and PDF reading flow (both apps).** Use the
  `.build/text-processing/delivery-b/listening/index.html` if retained locally
  (archived Delivery B fixture page), or equivalent disposable fixtures.
  In Libro, preview `paragraphs.txt` and `reading-flow.pdf`: blank lines remain
  paragraphs, single line wraps stay within them, `[12]` and hard hyphens remain,
  and only the discretionary soft hyphen disappears in speech. Compare PDF source
  and narration: known recurring titles/decimal folios are omitted with notices;
  all body sentences remain in order, including the demonstrated page continuation.
  Listen to Heart before/after at 1.0×; levels and accepted gap durations are unchanged.
  Check representative digital/scanned/mixed/rotated/multi-column books, contents,
  captions, notes, refrains and legal text: uncertain layouts/unknown margin prose
  should stay present rather than being guessed away. Review layout warnings and
  measured progress; cancel during preparation and ensure the next job stays correct.
  In VoiceRelay, use a disposable authorized PDF source/review to check the same
  notices, retained original and spoken flow. Old retained snapshots lacking geometry
  should remain unchanged until an explicit new extraction. Earlier EPUB, image,
  GUI, private-file and live-service checks remain separate. Report false omissions,
  missed joins and unexpected pauses without sharing private text.

- [ ] **B07 — Experimental printed PDF word joins (both apps).** In Libro Settings
  → Document or VoiceRelay General → Document Narration, enable **Join split words
  in PDFs (experimental)** for a new disposable
  job and compare source, spoken preview and Kokoro/Soprano listening. Printed
  `particu-` / `larly` should become `particularly` with a repair notice. Original
  source/navigation must stay intact. Compare the default-off behavior and check
  that a saved choice survives relaunch and affects future jobs. Explicit paragraph
  gaps, heading/column changes, OCR and missing geometry should abstain. An excluded
  auxiliary continuation must leave the preceding hyphen intact. Recognized compounds
  such as `well-` / `known` should become `well-known`; unknown spellings abstain.
  Check supported two-column order, full-width headings, tracked titles and ordinary
  word pairs. Repeated isolated chapter/volume labels and folios disappear without
  enabling any setting; body refrains and real headings remain. Existing recordings and queued
  captured choices must remain unchanged; no old snapshot is implicitly refetched.
  Automated preparation equality and decoded audio are not listening acceptance.

- [ ] **B08 — Scientific equations and tables (both apps).** Compare original
  pages with narration for the authorized scientific PDFs or equivalent
  disposable documents, using a fresh import/analysis. Retained snapshots are not
  implicitly re-extracted. Use the explicitly selected current build. `.build/FlowNarrationValidation/` is an
  earlier per-feature candidate, not a required or automatically current bundle.
  Clear linear notation should name operators/variables;
  detected complex expressions should produce one original-text reference notice
  per document, without repeating after prose, new pages or headings. Each omitted
  expression must retain its original range/page and surrounding explanations. Inline equals
  signs must not become display-equation cues. Check simple labelled tables,
  verbose entries, missing headers and ambiguous image/merged grids. Prose entries
  should read naturally without repeated row/column labels, including brief headings
  and quantities in a prose inset. Numeric values need reliable labels. Check top,
  middle and bottom OCR insets, nearby captions and explicit note links: paragraphs
  stay intact; bottom-quarter insets follow the page body. Long numeric tables
  must state how many brief rows remain in the source. Inspect targeted table OCR
  against its image, cancel during analysis, and confirm native prose remains
  available. Listen with both supported engines in Libro; no inferred formulas,
  units, values or scientific conclusions should be presented as source facts.
  See [scope and limits](SCIENTIFIC_NARRATION.md) and the
  [expanded corpus findings](ACADEMIC_PDF_EVALUATION.md); automated preparation passes
  do not establish mathematical transcription, GUI or listening acceptance.

## Model evaluation (developer utility)

- [ ] **B09 — Long-form quality candidate (both apps).** See
  [quality controls and limits](LONGFORM_QUALITY.md) and the
  [paired comparison commands](../tools/TTSBenchmark/README.md#product-phrasing-comparisons).
  **Partial listening result, October 30:** the operator preferred semantic
  phrasing for Kokoro/Heart and rated the other four pairs Same. Pronunciation
  and model-specific pacing issues remain; see the
  [recorded results](LONGFORM_QUALITY_LISTENING_RESULTS.md). GUI, recognition and
  broader acceptance remain unconfirmed. The operator subsequently approved
  semantic phrasing as Kokoro's only preparation path. Retest compound flow
  (“behind-the-scenes”, “state-of-the-art”) after the hyphen correction.
  Compare the numbered A/B recordings in generated `comparison.html`, preserving
  blinding until all choices/notes are saved. Evaluate multi-minute continuity,
  names, read/lead ambiguity, quantities, dialogue, closing quotations and joins;
  note fatigue and total generation time. Do not infer acceptance from EOS or
  basic audio flags. In each app, confirm Kokoro has no semantic switch and always
  uses that policy, including with older preferences. Other models retain an
  initially-off switch whose saved selection survives relaunch. Optional spoken forms stay English-only and
  Qwen presets preserve custom delivery until explicitly changed. Test advanced
  language/document/model pronunciation scopes, sentence preview and approved
  repeated-name drafts with disposable text. Enable retention for new disposable
  narration; select/play/check a passage, stop during recognition/regeneration,
  start normal work and quit to check joined ownership. Missing local recognition
  assets must report unavailable without download/service fallback. Explicitly
  regenerate one passage, optionally replan/apply updated rules, and export to a
  new WAV. Compare untouched passages, structural gaps and original recordings;
  no published audio/feed/transcript may change. Remove retained takes and check
  finished exports remain. Retention can be partial after failure/resume; it must
  not turn an otherwise successful audio render into failure. Accept candidate
  defaults only after recording this result; current accepted defaults remain.

- [ ] **M01 — Narrator preferences and finalist confirmation.** Use the
  [Swift benchmark guide](../tools/TTSBenchmark/README.md) to open the generated
  blind local-web bracket (`bracket.html` in the run folder, rather than the
  developer source `bracket-template.html`). In Safari, check that the opening
  notice disappears, controls align with the audio players, and a narrow window
  stacks the players without horizontal scrolling. Compare the same passage in each pair; record a
  preference, tie, neither or pause and resume as needed. Check browser save/reload,
  progress-file backup/restore, notes and revisions. Names and original audio
  paths stay hidden; reveal is available only after completing the bracket and
  explicitly selecting its identity file. Cold/warm variants and
  product-reference duplicates are performance evidence, not extra entrants.
  After choosing a top narrator and runners-up, generate the separate held-out
  blind finalist pack and coherent long-form recordings. Record naturalness,
  phrasing, wrong/repeated words, pacing, consistency and fatigue; note playback
  volume changes because audio levels remain unadjusted. Keep undecided results
  unassessed. This evaluation does not change either app's defaults or approve
  model integration/licensing for distribution.
  Reconfirm Ryan, Chatterbox default and leah through production preparation and
  paragraph assembly using held-out long prose, then other voices/languages as
  needed. New Chatterbox output disables the old SDK's normalization/fade, so
  compare loudness as well as prosody. During a background Orpheus article,
  request Libro Qwen narration and check waiting, completed-utterance yielding,
  Stop/Quit and reload behavior. Repeat alternating jobs and model switches while
  observing app responsiveness and host/helper memory. Keep actual-document and
  linguistic-quality findings separate from short native smoke results.

## Conditional installation and distribution checks

- [ ] **D01 — Relocated packaged apps.** On another supported Apple Silicon Mac
  or clean test account, run copies outside the checkout without Xcode. Explicitly
  install models, generate/listen offline and check setup/sample behavior. Existing
  working installations/caches need not be deleted for this test.
- [ ] **D02 — Public distribution, only when planned.** Validate the intended
  signing identity/entitlements, Developer ID/notarization or App Store route,
  downloaded-app Gatekeeper behavior and stable credential access on a clean Mac.
  Ad-hoc archive verification does not establish these. Engineering release/package
  gates remain in [VoiceRelay's release checklist](../VoiceRelay/docs/RELEASE_CHECKLIST.md).

## Reporting results

Report IDs as **Pass / Fail / N/A** (for example `L10 Fail`, `V12 Pass`, `D02 N/A`).
For a failure include the app/build, input type or private alias, action, visible
error and whether memory belonged to the app or helper. A screenshot or sanitized
log excerpt is enough; keep documents, private URLs and credentials private.

Listening pages from completed comparison rounds remain with the original
repository archive. The new checkout retains their accepted decisions and test
corpora; it does not copy generated development reports or build state.
