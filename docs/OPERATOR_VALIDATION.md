# Consolidated app validation checklist

Updated October 15, 2026. This is the single current operator checklist for Libro
and VoiceRelay. Earlier UI, beta, Settings, pronunciation and longform handoffs
are consolidated here; their implementation/build evidence remains in the
[implementation status](IMPLEMENTATION_STATUS.md) and
[longform record](KOKORO_LONGFORM_IMPLEMENTATION.md).

## Before starting

- Quit older copies of each app. Current ad-hoc Release apps, relative to the
  `swift-packages` folder, are
  `../Libro-TTS/macos/.build/DerivedData/Build/Products/Release/Libro.app` and
  `../VoiceRelay/DerivedData/Build/Products/Release/VoiceRelay.app`. These include
  the PDF subtoken-range fix; earlier `accepted/` exports predate it. Rebuild and
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
- Known pending corrections: `kg`, combined temperature forms such as `18°C`,
  and some contextual `lead`/`read` pronunciations remain frontend limitations.
  Record additional examples separately from pacing. See the
  [normalization research and follow-up](TEXT_NORMALIZATION_RESEARCH.md).

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
  RTF and PDFs, including folders. Check duplicate imports, long names, editable
  output names, selection/removal and keyboard shortcuts without disrupting typing.
- [ ] **L06 — PDF/OCR quality.** Compare selectable-text, scanned, mixed and
  multi-column PDFs, including contents pages with dotted leaders, with their
  previews: reading order, paragraphs, lists, notes,
  beginnings/endings, and visible table/code omissions. An unusable PDF should
  fail clearly without discarding other documents. Footnotes follow the preview's policy.
- [ ] **L07 — Preparation progress.** On a longer mixed PDF, check file/structure,
  page/OCR counters and the separate image-review pass when available. Pronunciation
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

## Conditional installation and distribution checks

- [ ] **D01 — Relocated packaged apps.** On another supported Apple Silicon Mac
  or clean test account, run copies outside the checkout without Xcode. Explicitly
  install models, generate/listen offline and check setup/sample behavior. Existing
  working installations/caches need not be deleted for this test.
- [ ] **D02 — Public distribution, only when planned.** Validate the intended
  signing identity/entitlements, Developer ID/notarization or App Store route,
  downloaded-app Gatekeeper behavior and stable credential access on a clean Mac.
  Ad-hoc archive verification does not establish these. Engineering release/package
  gates remain in [VoiceRelay's release checklist](../../VoiceRelay/docs/RELEASE_CHECKLIST.md).

## Reporting results

Report IDs as **Pass / Fail / N/A** (for example `L10 Fail`, `V12 Pass`, `D02 N/A`).
For a failure include the app/build, input type or private alias, action, visible
error and whether memory belonged to the app or helper. A screenshot or sanitized
log excerpt is enough; keep documents, private URLs and credentials private.
