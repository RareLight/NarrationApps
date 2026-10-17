# Consolidated app validation checklist

Updated October 16, 2026. This is the single current operator checklist for Libro
and VoiceRelay. Earlier UI, beta, Settings, pronunciation and longform handoffs
are consolidated here; their implementation/build evidence remains in the
[implementation status](IMPLEMENTATION_STATUS.md) and
[longform record](KOKORO_LONGFORM_IMPLEMENTATION.md).

The operator confirmed both apps build and run on October 16, 2026. Basic
relocation/build/launch smoke is accepted; individual feature, quality, data and
live-service cases below remain unconfirmed unless explicitly recorded elsewhere.

## Before starting

For the development-foundation-only final smoke, focus on the existing setup,
Settings, small synthetic import/preview/queue and Stop/Quit flows: Libro
L01/L02/L05/L12/L18 and VoiceRelay V01/V02/V10 in an authorized disposable test
setup. This is not a request to repeat model downloads, live Publishing, listening
or private-document quality tests; those existing unreported cases stay open.

Use the active workspace at
`/path/to/NarrationApps/NarrationApps.xcworkspace`.
First complete the [relocation smoke and archival gate](REPOSITORY_LAYOUT.md#migration-validation-and-archival-gate).

Earlier feature validation used synthetic generated fixtures at
`.build/cover-navigation/fixtures` (EPUB notes/appendix/bibliography/duplicate
headings, Markdown headings and covers). Those generated outputs were not migrated;
maintained Swift fixtures/tests remain. Use equivalent disposable documents and
artwork for the operator checks below. Actual-document/player acceptance remains
separate from automated fixture tests.

- Quit older copies of each app. Current ad-hoc Release apps, relative to the
  NarrationApps root, are
  `.build/WorkspaceDerivedData/Build/Products/Release/Libro.app` and
  `.build/WorkspaceDerivedData/Build/Products/Release/VoiceRelay.app`, built together
  with stable Xcode 27.1. Use the [combined workspace](../NarrationApps.xcworkspace)
  for simultaneous GUI development; select each app scheme to run it. These include
  the EPUB/encoding changes and PDF subtoken-range fix; earlier `accepted/` exports
  predate these. Current sources also include cover art, authored navigation and
  explicit note/auxiliary narration controls. Rebuild and
  re-archive current sources before testing a new exported copy.
- Use a separate output folder and disposable test articles. Keep existing models,
  finished audio and the live library intact. For fresh-install tests, use a
  separate macOS user/test installation rather than deleting working caches.
- Use your normal team/profile-signed VoiceRelay build for existing Keychain
  credentials and live Publishing tests; the ad-hoc copies do not establish
  account/entitlement acceptance. Installation/relocation and restore tests are
  conditional; mark N/A until a suitable test user/library is available.
- Automated suites, archives, signatures, offline workers and arbitration already
  passed. The twelve-pair A/B listening decision is complete; you do not need to
  repeat it. New Kokoro settings use Heart at 1.0× with the accepted pause profile;
  existing saved speeds and admitted jobs keep their values.
- New Kokoro spoken forms expand explicit kilograms, Celsius/Fahrenheit and
  AM/PM times; use B05 for their listening/preview acceptance. Contextual `lead`/`read`
  and unsupported/ambiguous forms remain limitations. See the
  [normalization record](TEXT_NORMALIZATION_RESEARCH.md).

## Libro

- [ ] **L01 — Launch and setup.** Existing models are recognized. In a fresh test
  user, try Not Now, installation, cancellation/retry and successful dismissal of
  setup; also try Choose Existing Models. Check Speech Setup works offline after
  installation. Select a British voice and install its regional resources if asked.
- [ ] **L02 — Settings and appearance.** Visit General, Models, Pronunciation and
  Troubleshooting. Test text size at 80%, 100% and 200%, ⌘+/⌘−/⌘0, minimum window
  sizes, light/dark, reduced motion/transparency, contrast, keyboard focus and
  VoiceOver. Help, long errors and controls remain readable; preferences persist.
- [ ] **L03 — Voice samples.** Try every presented voice, including Soprano.
  Play/Stop and switching voices work without installed models; finished-audio
  playback does not overlap. The common phrase starts “Hello, I can narrate…”
  and plays at recorded 1.0×, independently of generation speed/overrides.
- [ ] **L04 — Pronunciation.** Add, edit and remove a temporary override such as
  `SQLite` → `sequel lite`; use Play with the selected voice/speed. Narrate text
  containing both `SQLite` and `SQLites`: only the complete key should change,
  while original source prose stays intact. Check busy/missing-model guidance.
- [ ] **L05 — Import and queue.** Use Open and Finder drag/drop for text, Markdown,
  RTF, PDFs and DRM-free EPUBs, including folders. Check duplicate imports, long names, editable
  output names, selection/removal and keyboard shortcuts without disrupting typing.
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
- [ ] **L13 — File errors and replacement.** Test an empty text file, a locked or
  unreadable PDF, duplicate output names and an unavailable destination. Recovery
  messages/Details are actionable; cancelling replacement or a failed job preserves
  existing complete output. Re-selecting a destination restores normal generation.
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
  folders and Finder/drop. Compare chapter order, beginnings/endings, headings,
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
- [ ] **L19 — Document Narration settings.** Compare Current Placement, End of
  Document and Omit for marked notes. Turn Include auxiliary sections off/on.
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
  fresh test user, check Not Now, explicit Install Speech Model, cancellation/retry
  and successful dismissal. Check Speech Setup works offline; startup/checking must
  not silently download. Check the British voice resource-install path when needed.
- [ ] **V02 — Settings and presentation.** Visit General, Pronunciation, Publishing
  and Troubleshooting. Check 80%/100%/200%, ⌘+/⌘−/⌘0, small/large windows, keyboard,
  VoiceOver and appearance/accessibility options. Open/close Settings and Help during
  work: they remain responsive and Help performs no processing or network operation.
- [ ] **V03 — Voices and samples.** Check saved voice/speed preferences, new Heart
  1.0× defaults, the shared voice names and 0.05× speed steps. Try every presented
  sample, Stop and switching voices while idle/busy. The new common phrase is
  bundled and plays at 1.0× without models or pronunciation overrides.
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
  existing credentials, denied/cancelled Keychain access and Test Connection.
  Settings/errors remain responsive; denied access does not cause repeated prompts.
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
  Changing to a test destination preserves old-host copies and avoids old-host deletes.
- [ ] **V15 — Backup/restore (dedicated test library).** Back up while idle, then
  restore through Troubleshooting and review Articles/Queue/Server Audio. Identity,
  saved dates and retained text survive; credentials/preferences remain separate.
  Sync/automation/delivery stay gated until Finish Library Review. Preserve the
  backup and previous library; do not experiment on your only live copy. No CLI is required.
- [ ] **V16 — Diagnostics.** Try sanitized session-log Copy/Clear while idle;
  messages and busy states are clear. Source/setup/publishing failures route to the
  relevant Settings pane. Keep real URLs, credentials and source text out of reports.

- [ ] **V17 — Podcast Cover.** In Publishing, choose the square fixture or an
  opaque JPEG/PNG of at least 1400 pixels per side. Reject the transparent fixture
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
  change Notes and Include auxiliary sections, then add new articles with marked
  notes/appendices. Confirm preview and generated content agree, bibliography and
  unclassified text remain, and queued articles keep their captured settings
  when preferences change. Already published audio remains unchanged.

## Both apps together

- [ ] **B01 — Shared dictionary.** Save a pronunciation change in one app and
  confirm it appears in the other. Try competing edits: Reload/conflict handling
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
  `spoken-forms.txt` beside the `.build/text-processing/delivery-a/listening/index.html` (archived listening fixtures).
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
  temporary overrides afterward. Do not begin Delivery B until this review.

- [ ] **B06 — Paragraph and PDF reading flow (both apps).** Use the
  `.build/text-processing/delivery-b/listening/index.html` (archived Delivery B fixture page).
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

- [ ] **B07 — Experimental printed PDF word joins (both apps).** In Document
  Narration, enable **Rejoin PDF word wraps (experimental)** for a new disposable
  job and compare source, spoken preview and Kokoro/Soprano listening. Printed
  `particu-` / `larly` should become `particularly` with a repair notice. Original
  source/navigation must stay intact. Compare the default-off behavior and check
  that a saved choice survives relaunch and affects future jobs. Explicit paragraph
  gaps, heading/column changes, OCR and missing geometry should abstain. An excluded
  auxiliary continuation must leave the preceding hyphen intact. The draft rule
  deliberately also turns `well-` / `known` into `wellknown`: inspect compounds
  and turn the option off for unsuitable books. Existing recordings and queued
  captured choices must remain unchanged; no old snapshot is implicitly refetched.
  Automated preparation equality and decoded audio are not listening acceptance.

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
