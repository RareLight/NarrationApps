# Validation evidence

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
GUI/Canvas and live WebDAV hosting deletion were not run by the agent.


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
[KOKORO_PROVIDER.md](KOKORO_PROVIDER.md#october-7-bounded-single-worker-optimization).



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
with Copy. Public and upload folder addresses remain distinct because WebDAV hosting's
website Publish folder controls the public mapping. No mapping is guessed.

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

Provider-specific setup details are omitted. The provider's published website root can differ from its WebDAV root; map both URLs to the same feed and media files using the provider's instructions.

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
defines DAV:getcontentlength as the representation length. No WebDAV hosting-specific
HEAD behavior is asserted without live response metadata.

Provider-specific setup details are omitted. The provider's published website root can differ from its WebDAV root; map both URLs to the same feed and media files using the provider's instructions.

Provider-specific setup details are omitted. The provider's published website root can differ from its WebDAV root; map both URLs to the same feed and media files using the provider's instructions.

| Area | Evidence and limits |
| --- | --- |
| Core fixtures | All 36 delivery tests passed, including cases for missing/malformed/mismatched/unsupported HEAD, matching DAV size for feed and file uploads, encoding headers, strict metadata rejection, cancellation/auth/redirect preservation, saved verification-failure retry, public-vs-DAV path independence and feed-size failure blocking deletes. The parameterized feed-failure test covers PUT failure and metadata failure. |
| App suite | All 71 app tests passed. Source-local inert delivery controls still construct. |
| Build/static | Xcode Debug build succeeded; strict codesign verification and diff whitespace checks passed. Project references were unchanged. |
| Live boundary | Only user-authorized unauthenticated public GETs and nonsecret preference reads were run. No app GUI, credentials, authenticated DAV calls, uploads, hosting changes, local-state writes or subscriber updates. Actual WebDAV hosting getcontentlength compatibility and matching public Publish folder remain operator acceptance. |

Logs: `var/validation/2026-10-07-webdav-size/` (gitignored).

Provider-specific setup details are omitted. The provider's published website root can differ from its WebDAV root; map both URLs to the same feed and media files using the provider's instructions.

## October 7 WebDAV paths and existing-folder handling

Provider-specific setup details are omitted. The provider's published website root can differ from its WebDAV root; map both URLs to the same feed and media files using the provider's instructions.

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
readable folders never receive MKCOL, including WebDAV hosting's account/files
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
Troubleshooting. In Delivery, use the WebDAV hosting files-directory endpoint
`https://webdav.example/` (or the full account/files path on the DAV host),
the independently verified original full login username and Files-enabled app
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

## October 4 queue reliability, background add and Article Preview

The user reported an idle gap between articles and requested: prepared
speech-helper reuse across a batch, privacy-safe helper error mapping, removal
of Reading List exclusions, background Add to Queue with pending rows,
simplified toolbars/menus, a segmented Settings selector, and article preview in
a dedicated window.

| Area | Evidence and limits |
| --- | --- |
| Helper diagnostics | `runtime/kokoro/provider.py` adds `"detail": type(error).__name__` only for a fixed whitelist (MemoryError/OSError/RuntimeError/TimeoutError/OverflowError/EOFError); no messages, paths or content are emitted. `ExecutableSpeechBackend.exchange` maps `not_prepared`, `invalid_audio`, `empty_audio` and `synthesis_failed` to distinct role-specific messages; an engine-error detail is appended only for short alphabetic tokens (≤40 chars), and completed-chunks retention is always stated. |
| Batch session reuse | `runQueuedBatch` keeps one active provider and reuses it while candidate `BackendIdentity.id` matches and its session is alive; differing candidates cancel/replace it, and the batch cancels the active provider exactly once on success, error or cancellation. `FixtureCoordinator.execute` no longer cancels the backend — ownership moved to the queue path — removing the per-article helper/model reload. |
| Writer busy | `RelayError.writerBusy` distinguishes immediate `sqlite3_try_acquire` contention; `metadataWriter` retries briefly with bounded sleep. Covered by concurrent contending-writer tests. |
| Exclusion removal | `ReadingListCatalog.reconcile` clears legacy `excludedIDs`; `SpeechQueue` no longer checks exclusion before enqueue/claim and its `setExcluded` gate is gone (old paused/done rows surface via `errors`/`checkpoints` instead). App UI drops the row badge/menu item; app-level `setExcluded`/`excludedIDs` is removed. Legacy excluded/paused entries are retryable per tests. |
| Background add | `AppModel.addSelectedToQueue` returns immediately, clears the selection, stamps `pendingAdds` rows (*Preparing…*) and processes in displayed order on a tracked `Task`; per-entry failures collect as `enqueueIssues` and later entries still attempt. A new click supersedes the in-flight add. |
| UI structure | Settings uses a segmented General/Troubleshooting `Picker`; the audio folder row shows the full middle-truncated path with `.help` carrying it. Generate/Stop moved from the shared workspace toolbar to the Queue toolbar (and stay in the status menu); Articles toolbar is Add to Queue + Refresh, Saved Audio toolbar is Refresh, Queue's actions menu is a single destructive `Reset Queue…` button plus the per-row Remove menu. Icon/ambiguous controls gained `.help` tooltips. RelayMenu rows are Articles/Queue/Saved Audio + Settings…, Generate Audio/Stop Generating with counts/status, About, Quit. |
| Article preview | `WindowGroup("Article Preview", for: URL.self)` + `ArticlePreviewView`/`ArticlePreviewModel` fetch with `PageFetcher` default limits and `ReviewedSource.prepare`, cancel on disappear, and do nothing inert. Shared `ArticlePreviewContent` renders title/URLs/issue/blocks/chunks. Articles double-click and **Preview Article** open it via `openWindow(value:)`; Troubleshooting keeps entry/URL diagnostics with a **Preview** button. `WindowPresence` does not count MenuBarExtra windows. |
| Tests | Focused run (repo-local caches): **31 core + 10 app tests passed** covering error-code mapping/detail privacy, same/differing-identity batch reuse prepare/cancel counts, writer contention/retry/no-mutation, legacy paused retry, background add pending rows and per-entry failure isolation, inert Settings/preview construction and queue reset. A subsequent full suite run had **one unrelated failure**: `agentClientTimesOutAndRejectsInvalidTimeoutsWithoutConnecting` exceeded its 5 s bound (~11.5 s) under parallel load and **passed standalone in 0.033 s** — AgentClient was unchanged; executor contention is plausible, not proven. Logs: ignored `var/validation/2026-10-04-queue-preview-ux/`. |
| Build | `xcodebuild` Debug `VoiceRelay` scheme, `var/validation/2026-10-04-xcode-source-wiring/DerivedData`, `-disableAutomaticPackageResolution`: **BUILD SUCCEEDED** (`xcodebuild.log`). `git diff --check` exit 0. Pre-existing warnings only: multiple matching destinations, signed-agent strip skip, AppIntents metadata skip, and the historical always-true `is NSError` assertion in CoreTests. New app source files were added to `project.pbxproj`; the project-reference regression filter was included in the focused run. |
| Limits | Compile/test evidence only — rendered layout, menu dismissal, preview-window chrome, double-click behavior, actual helper reuse timing, listening, Safari access and TCC prompts are unverified operator gates. No GUI automation or live Reading List contact was performed. |

## October 4 storage reconciliation, helper scratch and Reset Queue

The user confirmed: the Safari Reading List plist and its entries stay strictly
read-only; Reset Queue is an explicit confirmed option removing only native
queue membership; Saved Audio shows only existing, accessible finalized files;
confirmed externally deleted media retires from listings and the local feed
while text/identity persist for explicit regeneration; an unavailable volume,
unreadable folder or linked path is never deletion; inference-helper scratch
moves to app-owned system temporary storage while persistent runtime/model/cache
assets and explicit installer scratch stay project-local. Settings is one fixed
880×680 window with stationary capsule pane controls using SwiftUI
glass/glassProminent styles (source/layout-constant coverage only — rendered
glass appearance, resizing behavior and click positions are unverified).

| Area | Evidence and limits |
| --- | --- |
| Helper scratch | `ExecutableSpeechBackend` allocates a private 0700 UUID child per session under an injected root that must be strictly inside canonical system temporary storage: `/`, home, outside-temp and linked roots are refused before any creation, the root must be an owned private directory, the child uses POSIX `mkdir` (EEXIST refused), and only the newly created child is removed on guard failure or when its worker stops. `KokoroMLXBackend` passes `AppStorage.temporaryWork/SpeechHelper` and no longer points `TMPDIR` at project `.runtime/tmp`; persistent runtime/model/cache and installer locations are unchanged. Documents read access for current runtime/model sources is unaffected — no TCC or signing change. |
| Missing-media reconciliation | `audioAvailability` probes the captured folder (real directory, readable/searchable, unlinked, captured volume UUID or conservative legacy `/Volumes` mount guard) then the file; an `ENOENT` file is rechecked against the same `st_dev`/`st_ino` folder identity before it counts as deleted, so a mid-probe unmount/rename/replacement reports unavailable, not missing. `reconcileMissingAudio` retires confirmed-deleted published rows to EXPIRED under the native writer, marks `feed_status.pending`, and re-renders the local feed from remaining published records — durable pending repair survives a failed feed write. Unavailable rows keep metadata and reappear when storage returns; no folders are created on unavailable states. A specific reconciliation/feed-repair warning is preserved over the generic unavailable-audio notice. |
| Volume identity | `Episode.audioVolumeID` is optional and decodes absent on old records; it is captured from the audio folder during managed setup and a mismatch refuses regeneration into a substituted volume. |
| Reset Queue | Queue actions menu → **Reset Queue…** with explicit confirmation; `FixtureCoordinator.resetQueue` runs only `DELETE FROM speech_queue` after storage validation and writer checks, refuses missing/foreign/newer/competing storage, and preserves Reading List inventory, exclusions, the plist, snapshots, episodes, audio and preferences. The app refuses while running/cancelling/stopping or with an empty queue. |
| Tests | Original increment combined filtered run (`storage-tests-final.log`, ignored `var/validation/2026-10-04-storage-reconciliation/`): **70 core + 15 app tests passed, 0 skips**. Review rework: `missingAudioFolderRaceNeverBecomesDeletion` first failed red returning `.missing` while its folder was renamed/replaced mid-probe (`race-before.log`); after the recheck fix the focused filter (missingAudio\*, speechHelper temp ownership/cleanup/unsafe-root rejection, resetQueue core + app, settings pane/layout, cleanup-warning preservation) passed **9 core + 4 app tests** (`rework-tests.log`). These are separate focused runs, not a full suite. |
| Build | `xcodebuild` Debug `VoiceRelay` scheme, prior recipe/DerivedData: `xcodebuild.log` **BUILD SUCCEEDED** for the original increment; `xcodebuild-rework.log` **BUILD SUCCEEDED** for this rework. Compile evidence only — no rendered layout, clicks or runtime behavior. Only pre-existing warnings: signed-agent strip skip, AppIntents metadata skip, and the historical always-true `NSError` assertion. |
| Live state | A one-time native queue/generated-history reset **was performed by the lead** after explicit user confirmation, app quit and prior backups. Frozen result (`var/validation/2026-10-04-ux-review/native-history-reset-result.json`, read as data only — not re-run or re-queried): speech_queue 1 → 0, episodes 18 → 0, snapshots 18 → 0, chunks 667 → 0; Reading List inventory byte-for-byte preserved; local feed 0 items; database/feed backups at `/path/to/home/Library/Application Support/VoiceRelayPrototype/Backups/audio-history-backup.sqlite3` and the same-basename `.feed.xml`; no media, Safari input, preference or runtime deletions. |
| Limits | One earlier `<3s` helper-descendant assertion failed inside the broad concurrent run and passed standalone and in the final pass; executor contention is plausible, not proven, and the deadline/ownership safeguard is unchanged. The original real missing-audio report remains unconfirmed — the reproduced missing/unavailable classification above is a verified path, not the established cause. GUI/Canvas rendering, Settings resizing, listening, TCC prompts and Safari access remain operator gates. |

## October 4 native menu/sidebar redesign and artifact diagnostics

The user selected the **native status menu** and **native sidebar** direction and
asked to remove the global Settings Cancel. They also reported the macOS
Documents permission dialog names **VoiceRelay** and the failed article does not
appear in **Saved Audio** — the failing artifact remains **unconfirmed**; the
missing-feed-audio diagnostic improved below is a reproduced *possible* path, not
the confirmed cause of that episode.

| Area | Evidence and limits |
| --- | --- |
| Menu | `MenuBarExtra` with `.menuBarExtraStyle(.menu)`: concise status line (batch phase/article/percent while running), Open VoiceRelay…, Generate Audio (ready count), Stop Generating/Stopping…, Settings…, Quit VoiceRelay. Preview disables window/settings/quit actions. `MenuPanelWindow`/dismiss hacks removed; `WindowPresence` still manages Dock/activation policy for ordinary scene windows. |
| Workspace | `Window("VoiceRelay")` (scene id `articles` kept) hosts `WorkspaceView`: `NavigationSplitView` + `.sidebar` List of Articles/Queue/Saved Audio, shared header with `ProcessingSummary`/`InlineNotice`, contextual Refresh + shared Generate/Stop in the toolbar, and a `CommandMenu("Audio")`. Availability comes from `canGenerateAudio`/`canStopProcessing`/`readyQueueCount`; presentation from `processingFraction`/`processingStatusLine` (floor-rounded, never 100% before validation; "Checking saved audio"/"Stopping…" states). |
| Sections | Articles keeps selection/order/exclusion; Add to Queue is a toolbar action. Queue rows show symbol+text state, per-item `lastError`, contextual Retry and a More → Remove from Queue menu. Saved Audio rows offer Play/Show in Finder (published) or Resume (unfinished); the Inspect window and its scene are removed. Empty sections use `ContentUnavailableView`. |
| Settings | Typed `TabView(selection:)` + `.tabViewStyle(.grouped)` — General (640×500: voice, speed, Reading List source, audio folder, retention) and Troubleshooting (880×640: existing source diagnostics, request-level **Stop Loading**), via an explicit selected-pane root frame rather than per-child minimums. No global Cancel; the earlier segmented header is replaced. `.windowResizability(.contentSize)` on the Settings scene. Whether this resolves the user's unclickable tab report is **not yet revalidated** — GUI acceptance is operator-owned. |
| Retired code | `RelayPanel`/`PanelState`/`PanelContainer`/`panelState`, `InspectionView` + scene, `MenuPanelWindow`/`MenuPanelRegistration`, `runFixture`/`generate(_:)`/parameterless `resume()` and the `pendingReview`/`pendingEpisode`/`pendingEntryID`/`lastRunWasQueue` fields — no remaining call sites. Core/CLI fixtures, `VoiceRelayAgent`, and dormant diagnostics files/tests untouched. |
| Diagnostics | `Files.hash` callsites now name artifact roles: feed-referenced "saved audio referenced by the local feed" (prior increment), "temporary article snapshot", "saved article source/text", "saved cleaned article", "saved narration", "prepared article text", "prepared narration", "cleaned article", "speech runtime sources or dependency pins". Messages disclose roles only — no URLs, paths, or content. Integrity checks unchanged. |
| Tests | Narrow filter (repo-local caches, `--disable-sandbox --skip-update`): **12 app + 6 core tests passed, 0 skips** (`final-tests.log`) — includes 4 new app tests (workspace sections construct inertly, generate/stop availability matrix, queue-row/global error deduplication, captured-settings resume) and 2 new core tests (runtime-source and snapshot read failures name their role without private paths). `artifact-roles-before.log` shows both new core tests failing red on the generic label pre-change. A later presentation/compactness rework ran a focused 5-test app filter (`presentation-tests.log`) including the new `processingPresentationKeepsFinishingBelowCompleteAndReportsWaitingWork` presentation-seam test, which first failed red against the previous rounding/labels (`presentation-before.log`). These are two separate focused runs, not a full suite. Logs in ignored `var/validation/2026-10-04-ux-review/`. |
| Build | `xcodebuild` Debug `VoiceRelay` scheme (prior recipe/DerivedData): `ux-review/xcodebuild.log` — **BUILD SUCCEEDED**; re-run after the presentation/toolbar rework as `xcodebuild-review.log`. Tests cover selection/availability/presentation seams only — not rendered clicks, menu dismissal, or actual Quit. |
| Signing/permissions | Read-only command-line inspection of the built Debug bundle: `Signature=adhoc`, `TeamIdentifier=not set`, designated requirement is cdhash. Runtime sources plus helper cache/TMPDIR paths under Documents can trigger folder access; build changes may alter code identity. Whether TCC re-approval persists across rebuilds is **not certified**. No privacy reset or runtime relocation performed. |

Design references visited: Apple HIG —
[Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos),
[Layout](https://developer.apple.com/design/human-interface-guidelines/layout),
[Materials](https://developer.apple.com/design/human-interface-guidelines/materials),
[Color](https://developer.apple.com/design/human-interface-guidelines/color),
[Typography](https://developer.apple.com/design/human-interface-guidelines/typography),
[Modality](https://developer.apple.com/design/human-interface-guidelines/modality),
[Design principles](https://developer.apple.com/design/human-interface-guidelines/design-principles),
[Settings](https://developer.apple.com/design/human-interface-guidelines/settings),
[The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar);
[Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass);
[Landmarks: refining the system-provided glass effect in toolbars](https://developer.apple.com/documentation/swiftui/landmarks-refining-the-system-provided-glass-effect-in-toolbars).
Standard chrome supplies Liquid Glass; no custom backgrounds or `glassEffect`
on content.

Operator gates still open: menu/sidebar behavior and dismissal, Settings pane
switching (incl. the user's unclickable-tabs report), real Quit paths, light/dark
and reduced-transparency rendering, Canvas previews, app-context Safari access,
real speech/listening, and the original unconfirmed missing-audio failure.

## October 4 app-owned lifecycle and Settings navigation repair

The user confirmed the product lifetime: processing and retention are owned by
the running app — live while VoiceRelay runs, stopped when it does not.
Persistent LaunchAgent/XPC ownership and SMAppService enrollment are superseded;
the bundled agent prototype stays dormant reference code. The user also reported
Settings' automatic tab labels rendered jammed together and unclickable
(screenshot). The exact rendering mechanism was **not** established — no GUI
reproduction was performed and this is not attributed to a framework defect.

| Area | Evidence and limits |
| --- | --- |
| Lifecycle | `AppModel.shutdown()` sets `stopping` before its first await, invalidates progress callbacks, cancels processing/library/maintenance and source review, then awaits `sourceReview.stop()` — which sets its own `stopping` flag before its own first await — **before** awaiting the processing, library and maintenance task refs; idempotent on repeated calls. `VoiceRelayApplicationDelegate.applicationShouldTerminate` routes standard macOS Quit through it (`.terminateLater`, one shared task); `quit()` now calls `NSApplication.terminate`. All work-beginning entry points plus `SourceReviewModel`'s task-starters refuse new work once stopping begins. Closing windows does not stop work. |
| Settings navigation | Implicit `TabView`/`.tabItem` + toolbar selector replaced by an explicit segmented **General/Troubleshooting** `Picker` bound to `SettingsSection`, with an independent Cancel control. The agent diagnostic is removed from active Settings (its file/tests remain dormant). RelayPanel's footer row now reads "Processing lifetime · While VoiceRelay is running". Whether the operator's unclickable tabs are resolved is **not yet revalidated** — GUI verification remains operator-owned. |
| Tests | `swift test --filter 'appShutdown|settingsSections|completedArticle…|cancelClearsStaleProgress…|cancellingWaitsForOwnedWorker…|failedGeneration…|audioRetentionRefresh…|xcodeProject…'` with project-local caches: **8 app tests and 1 core test passed, no skips**, including new `appShutdownWaitsForOwnedWorkAndPreservesQueue`, `appShutdownRefusesNewWorkAndIsIdempotent` and `settingsSectionsAreDistinctAndInertViewsConstruct` (selection seam only — not rendered clickability). Final-filter log: ignored `var/validation/2026-10-04-app-lifetime/app-lifetime-tests-final.log` (earlier `app-lifetime-tests.log` retained as historical). |
| Shutdown refusal evidence | `appShutdownWaitsForOwnedWorkAndPreservesQueue` uses a `holdCleanup` provider so the in-flight worker's cleanup is test-gated: while `AppModel.shutdown` was still awaiting it, `sourceReview.fetch` on an inert `file:` URL (rejected by `ArticleURL.validate` before any network or file I/O) incorrectly started (`busy → true`) when `sourceReview.stop()` ran **after** the task awaits — `shutdown-refusal-before.log` (exit 1). After moving `sourceReview.stop()` ahead of those awaits, the same call is refused (`busy` stays false) — `shutdown-refusal-after.log` (exit 0). These are worker-teardown code paths only; they do not exercise the AppKit delegate or real Quit, which remain operator-owned. |
| Build / limits | `xcodebuild` Debug `VoiceRelay` scheme (prior recipe, repo-local caches): **BUILD SUCCEEDED**; the changed `VoiceRelayApp.swift`/`SourceReviewView.swift` compiled in-target. Log: `var/validation/2026-10-04-app-lifetime/xcodebuild.log`. Only warning: benign `appintentsmetadataprocessor` skip (no AppIntents dependency). The earlier MenuPanelWindow wiring repair below was user-reported successful; the tab-clicking defect is user-reported failed and not yet revalidated. Remaining operator gates: Settings selector clicks, both Quit paths, reopening idle, app-context Safari access, real speech/listening, Canvas. |



## October 4 Xcode app source wiring repair

A user Xcode build failed with `Cannot find MenuPanelWindow` at
`VoiceRelayApp.swift:649`. Root cause: `project.pbxproj` defined object ID
`B1000000000000000000000C` twice — the `WindowPresence.swift` app source
buildfile and the `VoiceRelayAgent` embed buildfile — so the app Sources phase
resolved to the agent executable reference and `WindowPresence.swift` was never
compiled into the app target. The WindowPresence buildfile definition and its
Sources-phase reference were renamed to `B1000000000000000000000F`; the agent
embed/copy-phase entries are untouched. SwiftPM builds never observed the
defect because they ignore `project.pbxproj`, and `plutil -lint` only checks
plist syntax, not object-ID uniqueness.

| Area | Evidence and limits |
| --- | --- |
| Regression test | New `xcodeProjectAppSourcesUseUniqueBuildFileReferences` (Swift Testing, source-level, no Xcode required) asserts unique pbxproj object-definition IDs and resolves every app-target Sources entry to a `sourcecode.swift` file reference whose path set equals `Sources/VoiceRelayApp/*.swift` on disk. It **failed before the fix** (101 definition IDs vs 100 unique; the Sources entry resolved to `VoiceRelayAgent` with `WindowPresence.swift` absent) and **passed after** (all object IDs unique and all four app sources resolve). Logs: ignored `var/validation/2026-10-04-xcode-source-wiring/xcode-source-regression-before.log`, `xcode-source-regression-after.log`. |
| Command-line bundle build | `xcodebuild -project VoiceRelay.xcodeproj -scheme VoiceRelay -configuration Debug -destination 'platform=macOS' build` with repo-local DerivedData/module/package caches and `-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile`: **BUILD SUCCEEDED** — `WindowPresence.swift` compiled into target `VoiceRelay`, `VoiceRelay.app` produced (embedded `VoiceRelayAgent`, ad hoc "Sign to Run Locally"). Full log: ignored `var/validation/2026-10-04-xcode-source-wiring/xcodebuild.log`. Warnings concerned the signed embedded binary not being stripped and skipped AppIntents metadata. The earlier user-cache manifest diagnostic blocker did not recur with this repo-local-cache build command. |
| Checks / limits | `plutil -lint` passes on the project and packaging plists; `git diff --check` clean. GUI, Canvas and runtime behavior remain operator-validated; the build is Debug ad hoc only — signed distribution signing unexercised. |

## October 4 read-only agent snapshot client

The GUI gains an explicit read-only agent snapshot check in
Settings → Troubleshooting through `AgentClient`/`AgentTransport` and a private
XPC transport. The transport preflights the app's own trusted signature before
allocating a connection — ad hoc or unsigned builds refuse as
`untrustedIdentity` — and installs the agent peer-signing requirement that XPC
enforces during activation. Each check is a fresh connection with a bounded
deadline; correlated agent failures are preserved, malformed/uncorrelated
replies become a fixed invalid-response failure, and concurrent checks are
rejected without disturbing the in-flight one. No settings transfer, ownership
change, scheduling or enrollment is introduced.

| Area | Evidence and limits |
| --- | --- |
| Focused tests | `--filter 'agent|Agent'` with project-local Swift/module caches and `--disable-sandbox --skip-update`: **10 core and 4 app tests passed, no skips**. New checks cover lazy factory activation, exactly-snapshot requests, correlated endpoint success with no state creation, interruption/invalidation/unavailable mapping, `untrustedIdentity` refused at activation with no request sent, explicit reconnection with fresh transports, a 30 ms fixture timeout, invalid timeouts rejected before connecting, concurrent-request rejection, duplicate/late/stale-session callback immunity, cancellation of a scheduled task and an in-flight request with same-client recovery, public `cancel()` followed by an immediate fresh request, and malformed/oversize/wrong-version/wrong-or-nil-UUID/ambiguous (absent or doubled payload)/wrong-capability/negative-count/wrong-mode/progress-bearing replies plus preserved correlated storage and command-unavailable failures. Log: ignored `var/validation/2026-10-04-agent-client/agent-tests.log`. |
| Build / static | Debug core/app/CLI/agent/tests compiled during the filtered run. `.build/debug/VoiceRelayAgent --self-check` passed with no listener or persistent state. Project and packaging plist lint and `git diff --check` pass. Logs: ignored `var/validation/2026-10-04-agent-client/agent-self-check.log`, `plutil.log`, `git-diff-check.log`. |
| Limits / warnings | Fake transports only; no real XPC, listener, enrollment, preference, Safari or model activity was exercised. Signed peer acceptance, Canvas/GUI presentation of the diagnostics section, and an actual enrolled agent remain operator gates. The beta compiler aborted once while diagnosing an implicit `catch` variable shadowing the model's `error` field; explicit `self.` in the final source compiles. This run's log shows the deprecated `--skip-update` warning and the pre-existing always-true NSError assertion warning; unavailable user caches are a historical limitation, not observed this run. No Xcode bundle build, Release or full suite was run for this increment. |

## October 4 filesystem-based native audio retention

The user explicitly authorizes automatic audio expiry, superseding the earlier
retention deferral for native owned output. Settings → General → Storage now has
all ten requested options, with 1 month as the persisted default. File modification
dates determine age; calendar subtraction handles month choices. No age/deadline
timestamps or schema migration are added. Existing episode lifecycle uses EXPIRED
intent to retire local RSS enclosures before unlink and recover interruptions.

| Area | Evidence and limits |
| --- | --- |
| Scope / timing | Known completed UUID-named native M4A files only, in each episode's captured folder. Queue members, unfinished episodes, unrelated files, source snapshots, runtime/model assets and historical/reference output are excluded. Startup, refresh, policy changes, post-processing and an idle 15-minute app-open loop trigger the shared-coordinator sweep. No service enrollment, remote publication, startup inference or cleanup while quit. |
| Filesystem / recovery | Hash and regular-file checks precede retirement; file/folder links and changed media are refused. Empty/missing libraries and disconnected folders are not recreated. Feed failure leaves media intact, with retirement intent pending for retry. Never/longer retention can restore a pending entry whose intact file remains; deleted audio stays retired. Saved Audio/Inspect clear expired results, while retained source text/settings/identity allow explicit regeneration. Cancellation coalesces pending library reads without reviving stale progress. |
| Focused retention pass | `--filter audioRetention`, project-local Swift/module caches and `--disable-sandbox --skip-update`: **5 core tests plus 1 app test passed**, no skips. Covers ten options/default/JSON round trips, fixed-hour and calendar/leap-month cutoffs, filesystem dates independent of publication dates, Never, queue/unfinished/unrelated preservation, boundary dates, captured folders, feed failure/recovery, changed/linked media, regeneration and visible-library/Inspect removal. An initial guard incorrectly rejected macOS /var temporary aliases; it was corrected to inspect the captured folder and child. Log: ignored `var/validation/2026-10-04-audio-retention/focused.log`. |
| Broader regression / final targeted checks | Filter `audioRetention\|queue\|Queue\|VoiceRelayAppTests\|managed\|reviewedSpeech\|interruption\|damaged\|pendingFeed\|cancellationStops\|speechHelper`: **43 of 44 core tests and all 5 app tests passed** initially. The sole failure was the new test retaining its simulated competing writer while checking a disconnected folder. Explicitly releasing that test owner corrected the fixture; the final targeted test passed. After adding cancellation/refresh coalescing, the Debug app rebuilt and **all 5 app lifecycle tests plus the ownership test passed again**. Thus all 49 distinct selected functions passed across these runs; no full-suite pass is claimed. Logs: ignored `regression.log`, `ownership-final.log`, `app-final.log` in `var/validation/2026-10-04-audio-retention/`. Synthetic audio exercised actual ffmpeg/ffprobe; no real Kokoro or GUI run. |
| Build / static evidence | Debug core, app, CLI, agent and tests compile. The new core source appears in Xcode's source navigator and the shared package auto-includes it. Project/app plist lint and `git diff --check` pass. Existing inaccessible user-cache/deprecated-option and always-true test type-check warnings remain. No new Xcode bundle build, Release, GUI, Canvas or signed agent acceptance is claimed. |
| Operator gates | Confirm dropdown ordering/default, persistence through relaunch, disposable-file deletion using a deliberately aged modification date, Never behavior, visible-library/Inspect updates, regeneration and playback. Exact Terminal and Xcode steps are in [SOURCE_REVIEW.md](SOURCE_REVIEW.md#audio-retention). Actual app-open timing, folder access, listening and the previous window/Dock/menu checks remain operator-owned. |
| Preservation | Source and synthetic fixtures only; no live library, real audio, protected Safari file or model assets were modified by the agent. Historical Python/config/state/feed/audio and unrelated changes remain intact. No commit, uploads, downloads, enrollment, hosting changes or automated computer use. |

## October 4 queue completion, cancellation and window activation

The operator reports two-article aggregate progress/chunk totals functioning,
but a current-article label remained at 1/2, completed items stayed queued, and a
read failure left stale progress without recovery controls. The visible screenshot
shows ENCODING 5/25 and 0/2 after a queue action; the first screenshot was unavailable.
The exact unreadable artifact in that run is not established. No private live
library, Safari file, published media or runtime assets were read or modified in
this investigation.

| Area | Evidence and limits |
| --- | --- |
| Article progress | Fixed-batch updates now carry a one-based current index and emit it before each article starts. Completion counts advance after a verified coordinator return and queue acknowledgement. Labels display 1/2 then 2/2 independently of global chunks; the final aggregate has no active index. Existing optional-field decoding compatibility is retained. |
| Successful queue removal | New completed runs delete only queue membership after media hash/probe/decode and local feed commit. Episodes/snapshots/media remain. Legacy completed rows are reverified on explicit Generate Audio. Failed/cancelled/unfinished items remain; a published episode alone never triggers removal. Explicit manual Remove remains a separate user action. |
| Cancel/error recovery | Always-present Cancel clears stale progress/errors and invalidates late callbacks. An owned task stays busy until cleanup returns, preventing overlapping generation; failed/cancelled runs release controls and preserve unfinished entries/checkpoints. Earlier verified results remain inspectable after a subsequent failure. Artifact errors identify saved/staged/encoded audio or generated chunk roles without paths. |
| Focused regression / Debug build | Project-local module/SwiftPM caches, `--disable-sandbox --skip-update`, filter `queue\|Queue\|cancelClears\|cancellingWaits\|failedGeneration\|completedArticleLeaves\|managed\|reviewedSpeech\|interruption\|damaged\|pendingFeed\|cancellationStops\|speechHelper`: **38 core tests plus 4 app lifecycle tests passed, no skips**. The cancellation acknowledgement test includes encoding and published cases. Debug core, app, CLI, agent and tests compiled. Synthetic providers exercised actual ffmpeg/ffprobe. Lifecycle tests use injected isolated temp storage/providers, without preferences/Safari/GUI access. Earlier compile failures involving notification isolation, an overload function reference and throwing test macros were corrected before this final pass. Log: ignored `var/validation/2026-10-04-queue-recovery/regression.log`. Existing user-cache/deprecated-option warnings remain. No Kokoro inference/listening was run. |
| Native window/source integration | `WindowPresence.swift` is in the Xcode app compile phase and SwiftPM app target. Only standalone scene windows register; weak window references, close/key/visibility/minimize notifications and deferred activation updates leave MenuBarExtra windows out of the Dock decision. Panel window-opening buttons close their own attached menu window before activation/opening. `plutil -lint` and `git diff --check` pass. This is source/build evidence; no GUI, Dock, ⌘-Tab, menu reopening or Canvas behavior was exercised. |
| Final app check | After removing duplicate current-article labels, the Debug app rebuilt and **all 4 app lifecycle tests passed** again (`--filter VoiceRelayAppTests`). Log: ignored `var/validation/2026-10-04-queue-recovery/app-final.log`. No further source changes followed. |
| Outstanding operator gates | Build/run **VoiceRelay → My Mac** in Xcode. Validate current-article advance, automatic dequeue, Saved Audio playback, cancellation/Retry, errors if they recur, menu dismissal/reopening, multiple standalone windows, minimization and last-window close. Exact steps are in [SOURCE_REVIEW.md](SOURCE_REVIEW.md). App lifecycle tests currently run through SwiftPM; the Xcode test scheme retains core tests. No new Xcode app bundle build, Release/full suite, service enrollment, agent-context ownership, remote delivery or real speech acceptance is claimed. |
| Preservation | Existing unrelated changes (including an externally removed fixture example), historical Python/config/state/feed/audio, local model/runtime assets and dependency pins are preserved. No commits, uploads, service registration, GUI automation or hosting changes. This queue/UI correction precedes the planned agent client/ownership work. |

## October 3 global batch progress, naming and agent foundation

The operator reports the queue-first workflow working well so far; this is general
feedback, not an itemized report of specialized acceptance gates. Generate Audio
replaces Run queued speech, and Saved Audio replaces Saved speech. The coordinator
captures the waiting FIFO batch at click time. Global chunk counts accumulate
across articles; the bar counts chunks plus an encoding/publication completion
unit per article, remaining below 100% until the batch finishes. Cancellation
keeps earlier completed work and later waiting entries. Per-article inspection
results remain available if a subsequent item stops. Named inert global-encoding
preview added; normal sample/saved-article progress remains individual.

Continued Slice 4 with `AgentContract.swift`, a bounded version-1 Codable
command/status/error envelope, UUID correlation, read-only snapshot endpoint,
same-user/trusted-team NSXPC listener executable, shared package target and
Xcode/SwiftPM bundled LaunchAgent layout. The agent advertises snapshot only;
all mutation commands return unavailable. The GUI still owns processing. No
client, service registration, runtime download, automatic scheduling, enrollment,
upload or live-data migration is added. Ad hoc builds support the inert self-check;
listener mode requires trusted identities. This is foundation evidence, not
managed-worker, signed-peer or unattended acceptance.

| Check | Result and scope |
| --- | --- |
| Focused regression | **25 Swift Testing tests passed in one suite**, no skips, filter `queue\|Queue\|agent\|Agent\|readingList\|ReadingList\|durable\|Durable`. Six new checks cover global totals/monotonic encoding progress and completion, cancellation retaining earlier/later work, bounded/versioned malformed requests, read-only snapshots/mutation refusal and privacy, foreign-state preservation/reply correlation, and requirement construction with fixed identities. **Two batch tests passed again** after adding per-article completion callbacks; they are a subset, not two additional tests. Synthetic pages/providers with real ffmpeg/ffprobe; no Safari/network/real Kokoro. Logs: ignored `var/validation/2026-10-03-global-progress-agent/focused.log` and `final-batch.log`. |
| Build / self-check | Debug core/app/CLI/agent/tests compiled. Package builds and agent `--self-check` passed. Self-check starts no listener, creates no persistent state and performs no inference. Existing unavailable user-cache/deprecated SwiftPM-option and existing always-true NSError assertion warnings remain. |
| Packaging / static | An isolated generated app under the validation directory contains app/agent binaries, core resource bundle, acknowledgements and the LaunchAgent plist. Ad hoc agent/app signing and `codesign --verify --strict --deep` pass; packaged agent self-check passes. Project/app/agent plist lint, build-script syntax and `git diff --check` pass. This is bundle/layout/ad hoc evidence, not trusted signing or service registration. |
| Xcode / operator | Command-line Xcode build could not resolve the local package because the filesystem sandbox blocks manifest diagnostic output in the user cache. A retry with supported local cache/module options removed the module-cache failure but still could not write `~/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/voicerelay.dia` (exit 74). Neither attempt reached app/helper compilation; this is not an app compile failure. Xcode GUI build/bundle-copy checks, global progress/Canvas, real audio/listening and actual signed peer/service-context checks remain operator-owned. See SOURCE_REVIEW.md and AGENT_PROTOCOL.md. |
| Preservation / next work | Existing uncommitted changes, historical Python/customized config/state/feed/audio, installed runtime/model assets and dependency pins remain intact. UserDefaults keys and native schema are unchanged by this continuation. Changes remain uncommitted; no push. Next: configuration transfer, GUI XPC client and exclusive agent mutation/task ownership, followed by explicit SMAppService enrollment and actual-context validation; automatic FIFO scheduling and remote delivery remain later gates. |

## October 3 queue-first workflow and Settings troubleshooting

The operator reports article quality generally good and requests moving review
to Settings as a troubleshooting tool. This is quality feedback, not itemized
acceptance of the new workflow. Articles now supports multiple selection without
fetching, explicit sequential Add selected to queue, and Run queued speech. New
entries are fetched/prepared by the coordinator; saved entries reuse stored text
offline, retaining identity, captured choices and FIFO position. Failures/cancellation
retain earlier additions; the failed/unattempted selections remain in the UI.
Exclusions are skipped/rechecked after fetch. A diagnostic-created queue item
acquires its Reading List link when added from the list, enabling exclusion policy.
Semantic/narration/URL review moves to Settings → Troubleshooting and cannot
enqueue or start speech. The source picker is in Settings → General. Menu Run
uses the queue rather than implicit sample generation. Named inert previews are
retained for troubleshooting and added for normal multiple selection.

| Check | Result and scope |
| --- | --- |
| Focused tests | **19 Swift Testing tests passed in one suite, no skips**, filter `readingList\|ReadingList\|queue\|Queue\|durable\|Durable`. Six new checks cover displayed selection order/exclusion filtering, queueing without review/inference/scratch, offline duplicate/removal reuse and diagnostic linking, unavailable/excluded/mismatched source refusal, blocked/network/cancel retention, and exclusion recheck after an asynchronous fetch. Existing FIFO, durable retry/interruption, captured settings, writer-lock and read-only discovery checks pass. Fetches used synthetic injected pages; inference providers used synthetic WAVs with real ffmpeg/ffprobe. No live network/Safari/Kokoro access. Log: ignored `var/validation/2026-10-03-queue-workflow/focused.log`. Existing SwiftPM cache/deprecated-option warnings and an existing always-true NSError assertion warning remain. |
| Build / static | Debug app/core/CLI/tests compiled with the focused run. A subsequent Debug `swift build` passed after the final menu progress-display change; `git diff --check` and project/app plist lint pass. Build log: ignored `var/validation/2026-10-03-queue-workflow/build.log`. No dependency, runtime, model, deployment or signing changes. No Xcode GUI or Canvas execution. |
| Operator gates | New Settings tabs, multi-selection, queueing with no preview, source failure/cancel selection retention, captured choices, duplicate display and actual FIFO speech/listening require manual checks in SOURCE_REVIEW.md. Physical interruption/volume, final-agent/sandbox permissions, runtime relocation, long runs and remote delivery remain separate gates. |
| Preservation / future mode | Existing uncommitted work and historical Python/config/state/feed/audio remain intact. No GUI automation, downloads, enrollment, migration of live state, upload or hosting changes. Fully automatic FIFO mode is roadmap-only, explicit opt-in after agent/recovery gates. No timer or startup processing is introduced. Changes remain uncommitted; no Git commit/push attempted. |

## October 3 operator validation and durable manual queue continuation

The operator reports the preceding audio-folder, implicit article selection and
menu-font iteration **validated**. This is general operator acceptance of that
iteration; no itemized report, physical-volume, Canvas, crash, hours-long listening
or final-agent permission evidence was supplied. Those specialized gates remain
separate. This report does not certify the new queue behavior below.

The continuation adds persistent Reading List inventory/current membership and
exclusions, plus manual reviewed-article queue state, in native schema 3. Explicit
refresh/exclusion/enqueue mutations initialize or upgrade the app-managed library;
read-only initial snapshots create no store and access no Safari/network. Native
schema-1/2 upgrades add tables while preserving episode records and source blobs;
Python/foreign/newer stores remain refused. Add to queue atomically captures text,
episode identity, voice/speed and audio destination without inference or scratch
creation. Duplicate additions retain the same item/settings/order. Generate speech
runs only that article. Queue processing is FIFO and explicitly started, with
persisted running claims, pause/failure and manual retry. Excluding a waiting entry
pauses it. Include alone does not restart it. Queue removal preserves source/episode
and any audio. The GUI shares the existing actor and submits commands rather than
writing its own database. A named inert waiting/interrupted Queue preview is added.
No automatic backlog narration, retry timers, service enrollment or upload.

| Check | Result and scope |
| --- | --- |
| Focused regression / Debug build | **29 Swift Testing tests passed in one suite, no skips**; Debug core/app/CLI/tests compiled. Filter `queue\|Queue\|durable\|Durable\|nativeSchema\|managed\|reviewedSpeech\|libraryReadOnly\|interruption\|pendingFeed\|configuration\|ReadingList\|readingList`, project-local Swift/module caches, `--disable-sandbox --skip-update`. Ten new checks cover persisted inventory/exclusions and absence/error retention, enqueue with no scratch/audio and duplicate/captured-setting preservation, FIFO offline completion and immutable repeats, fixed failure diagnostics/cancellation/manual retry, simulated interrupted claims, exclusion/include/retry policy, removal/missing volume preservation, native schema-2 byte preservation, competing writer refusal before inference, and blocked-source refusal before storage creation. Existing native schema-1 upgrade and audio/recovery/read-only/source checks also pass. Synthetic WAV providers exercised real ffmpeg/ffprobe; no real model inference or live network/Safari reads. Log: ignored `var/validation/2026-10-03-durable-queue/focused.log`. Existing deprecated-option/unavailable user-cache warnings remain. |
| Static / Xcode project | `git diff --check` passes; project/app plist lint passes. The new shared-core source is visible in the Xcode navigator and compiled through the same local Swift package. No package/runtime/model pins changed; private config/model/runtime/generated directories remain ignored. Xcode GUI build/Canvas were not agent-run. |
| Operator / remaining gates | The new Queue tab, inventory/exclusion persistence, adding without inference, duplicate display, captured voice/folder, real speech/listening, Pause/relaunch/Retry, and unavailable-volume behavior need operator checks. The interrupted-claim test seeds durable state; it does not certify actual process-kill/power-loss recovery. See SOURCE_REVIEW.md's queue acceptance steps. Managed agent/XPC, relocatable runtime, automatic scheduling/backoff, signed/sandboxed/final-context permissions, representative corpus/long runs and remote delivery remain open. |
| Preservation | Earlier uncommitted storage/UI work is retained. Historical Python/custom config/state/feed/audio, original native workspaces and installed runtime/model assets are unchanged. No automated GUI, new downloads, enrollment, migration of live reference state, host cutover or uploads. Current changes remain in the working tree; no commit or push was attempted in this continuation. |

## October 3 audio-folder, temporary-work and article-selection correction

The operator confirms settings persistence but reports `Fixture storage is missing`.
Source inspection localizes that message to the old workspace guard requiring
private/work/media folders together. The app was still using that fixture layout
for normal generation. This check does not identify which folder was missing in
that past run; the default speech workspace's folders existed during the current
read-only inspection. The normal app now uses a separate managed storage route;
the strict fixture guard remains only for developer CLI/historical fixture APIs.

Settings now exposes one remembered audio-folder chooser, with no runtime,
sample-workspace or private-export directory chooser. Finished M4A files go there;
intermediate files use standard macOS temporary storage and completed episode
work is removed. Atomic publication briefly stages audio only beside the final
file, enabling cross-volume use without private data in the hosted folder. The
internal Application Support library retains a private SQLite index, approved
article text/raw provenance and local diagnostic RSS. Durable source snapshots
allow offline recovery after temporary-directory purge/reboot. Native schema 2
adds integrity-checked snapshots with a transactional native schema-1 upgrade;
Python/foreign/newer stores remain refused. Old native workspaces are preserved,
not automatically adopted. Changing audio folder affects new episodes; saved
episodes keep their destinations. RSS now validates each episode's own media path.

Selecting a Reading List article implicitly fetches/extracts/displays it; there
is no Review button. A request identity and cancellation prevent superseded
results/errors from replacing the latest selection. URL entry uses Open article
or Return. Selection never starts synthesis. Excluded entries still display;
generation stays disabled until included. Menu small text is 14 pt, status 15 pt
and footer 13 pt, with a wider panel and wrapping footer/error text.

| Check | Result and scope |
| --- | --- |
| Focused regression / Debug compilation | **21 Swift Testing tests passed, no skips** (the recovery-boundary test contains five cases), with project-local Swift/module caches, `--disable-sandbox --skip-update`, filter `managed\|nativeSchemaOne\|reviewedSpeech\|speechPreferences\|libraryReadOnly\|Fixture\|fixture\|interruption\|damaged\|pendingFeed\|symlink\|configuration`. Debug app/core/CLI/tests compiled. Seven new tests exercise audio-only destination contents and unrelated-file preservation, scratch cleanup/purge/reboot with immutable completed audio, offline unfinished recovery/captured settings, different audio destinations with complete RSS, missing destination/overlap refusal without creation, snapshot integrity/linked-output refusal, native schema-1 preservation/upgrade, and sample speech in the same library. Synthetic test WAV providers exercised real ffmpeg/ffprobe; no Kokoro inference was run. Log: ignored `var/validation/2026-10-03-audio-storage/focused.log`. Existing unavailable user-cache/deprecated-option warnings remain. |
| Static / project / exclusions | `git diff --check` passes; project/app plists pass `plutil -lint`. Source inspection confirms one app directory-output chooser (audio) and a separate read-only Reading List file chooser; the Review/sample/runtime/export directory controls are removed. `config.toml`, `models/`, `.runtime/` and `var/` remain ignored. |
| GUI / actual speech | Not agent-run. Operator steps cover folder/bookmark persistence, implicit loading and rapid selection/cancellation, larger menu/footer, actual speech/listening, pause/relaunch, folder changes and removable-volume refusal. Canvas, signed/sandboxed permission persistence, cross-volume physical device and hosting acceptance remain separate gates. See SOURCE_REVIEW.md. |
| Preservation | Historical Python/config/published data, project-local runtime/models and previous managed/fixture outputs were not changed. No model downloads, protected Safari reads, GUI automation, enrollment, host cutover or uploads. This new app library intentionally does not list/adopt historical workspace episodes; their files remain in place. |

The prior speech-only continuation was subsequently committed as `5811286`, as
verified by the current local Git history. The signing failure below is historical.
The present storage/UI changes are a new working-tree change.

## October 3 speech-only app and reviewed-article continuation

Created the requested local, SSH-signed checkpoint commit **`dc5fa24`** before
removing tone mode. VoiceRelay previously had no Git repository. The reviewed
74-file native checkpoint excludes customized `config.toml`, private/generated
`var/`, `.runtime/`, `models/`, build products and Xcode user state. No remote was
added or pushed; historical/reference directories remain untouched.

A separate continuation commit was attempted with the existing SSH signing
configuration, but the signing agent returned `communication with agent failed`
and Git did not create that commit. The validated continuation remains staged;
signing was not disabled. After unlocking/reconnecting the signing agent, the
operator can finish it with:

```sh
cd /path/to/VoiceRelay
git commit -m "Add speech-only article library and in-app preferences"
```

The app/CLI tone provider, default tone coordinator entry point, GUI mode picker
and CLI `fixture` command are removed. Deterministic synthetic audio now exists
only in test source. The legacy `BackendIdentity.isMock` checkpoint field remains
for serialization compatibility/refusal of classified non-speech providers; it
does not expose a product mode. Existing tone workspaces are preserved/refused.
CLI imports configuration only with explicit `--config`, except diagnostic doctor.

The app now exposes saved Heart/Bella/Emma and 0.75–1.5× speed preferences, with
Heart/1.0× defaults and fixed internal audio/fetch settings. Normal app use has no
TOML picker or output-folder requirement. The pinned runtime chooser and sample
speech folder are development diagnostics until runtime packaging is implemented.
The selected Reading List location is remembered; no durable inventory/exclusions
or permission persistence is claimed.

Slice 3 adds explicit speech from a readable reviewed article and an application-
managed private native SQLite episode library. It uses the existing supervised
TTS, checkpoint, encoder and local RSS services. Response bytes and reviewed
semantic content are saved under opaque IDs; source/work/state stay outside media.
Saved speech lists episode state with read-only SQLite, plays/inspects completed
items, and resumes saved reviewed content offline using captured options. Blocked
reviews, escaped/tampered snapshots and changed published revisions are refused.
An interruption before the extraction checkpoint is committed requires reviewing
again; durable fetching/queue policy remains open. No feed upload or service enrollment.

| Check | Result and scope |
| --- | --- |
| Focused native regression / Debug compilation | Filter `configuration\|Fixture\|fixture\|interruption\|damaged\|pendingFeed\|cancellationStops\|symlink\|speech\|reviewed\|sourceReviewArchive\|multipleArtifact`, with project-local Swift/module caches and `--disable-sandbox --skip-update`: **24 Swift Testing tests passed, no skips**. Debug shared core/app/CLI/tests compiled. Includes preferences defaults/JSON round trip, historical tone refusal without writes, reviewed semantic/raw-byte provenance, two-article RSS, offline published resume with unchanged media/feed, partial-chunk recovery/captured options, blocked-source refusal before storage creation, published revision preservation and tampered snapshot refusal, plus existing helper/recovery/audio checks. All audio synthesis was test-only synthetic WAV output; real ffmpeg/ffprobe encoding/validation ran. |
| Final incremental build / read-only storage | After adding inert ready/paused library previews and read-only storage/path safety checks, filter `libraryReadOnlyStore\|reviewedLibrary`: **2 tests passed, no skips**; final Debug core/app/CLI/test sources compiled. Foreign SQLite bytes remain unchanged; read-only checks create neither a writer lock nor a missing database. Library reads reject escaped/symlinked media before presenting saved files, and saved storage URLs must be local. No Swift source diagnostics; existing deprecated-option/user-cache warnings remain. |
| Static / CLI / recovery driver | Project/app plist pass `plutil -lint`; shared scheme XML parses; dependency locks remain aligned/unchanged; `git diff --check` passes. Built CLI help lists only speech-fixture, doctor, reading-list and review-url. Invoking the retired `fixture` command returns exit 1 with no output/storage creation. No product tone implementation or GUI mode property remains. The updated actual-speech SIGKILL recovery driver compiles with `swiftc` into temporary output; it was not executed. New settings/library previews are source-local and inert. Xcode GUI/Canvas rendering is not established by these checks. Logs are ignored under `var/validation/2026-10-03-speech-only/`. |
| Preservation | Model/runtime pins and assets, historical Python/config/state/feed/audio and prior project fixtures/snapshots were not changed. Download directories remain ignored. New source/tests/docs only; no live migration, network fetch, MLX execution, enrollment or remote publication was performed by the agent. |
| Operator acceptance / next work | Prior saved-fixture Kokoro success is operator evidence, not acceptance of this new GUI or real-article path. Verify settings/source-selection persistence, new tabs/Canvas, real-article completion/listening and pause/quit/relaunch recovery. Then implement durable Reading List inventory/exclusion/queue policy and Slice 4 agent/XPC ownership. Packaging/long-input/final-context/delivery gates remain open. Full native suite, Release and Xcode GUI build were not rerun. |

See [manual reviewed-article checks](SOURCE_REVIEW.md#reviewed-article-speech-and-managed-storage)
and the [current app workflow](../README.md#xcode-and-app-use).

## October 3 operator-confirmed Kokoro fixture

After rebuilding/retrying, the operator reports that Kokoro worked as expected.
The operator also reports **Metal API Validation was already unchecked**. This
is successful operator speech-fixture evidence; it does not establish that changing
that setting caused the recovery. The preceding crash reports remain valid, but
the precise trigger and reason for recovery remain unresolved. The agent did not
execute actual MLX inference or GUI/listening checks. Detailed listening, interrupted
recovery, long-input memory and final-agent acceptance still require separate evidence.

The operator now requests removal of the user-facing mock mode and continued
development. Settings must ultimately be editable in the app, with sensible
defaults, a few relevant choices, and application-managed opaque storage. TOML
files and manual pipeline parameters are not the intended product configuration
experience. Historical imports/data must remain untouched.

## October 3 GUI speech crash diagnosis and targeted workaround

The operator's screenshot shows Kokoro speech selected and `Speech helper exited
or closed its control connection`; no local episode/feed was generated. Read-only
inspection found three macOS Python crash reports at 10:25, 10:26 and 10:28 local
time. They identify VoiceRelayApp as parent/responsible process and show SIGABRT
(6) through `mlx::core::Gather::eval_gpu`, Metal's debug compute encoder `setBytes`,
`MTLReportFailure`, assertion and abort, on macOS 27.2 build 26B5091g. Those reports
establish an actual native helper crash in MLX/Metal. They do not contain the exact
assertion message or identify the failing narration chunk.

The stack closely matches [upstream MLX issue #4061](https://github.com/ml-explore/mlx/issues/4061),
an empty-vector Metal binding failure exposed by API Validation. That specific
mechanism remains inferred. The pinned dependency/model selection remains intact.
The shared VoiceRelay Run scheme now explicitly disables Metal API Validation as
a development workaround; inference with that setting remains an operator gate.
The generic process supervisor now reports startup/preparation/synthesis and the
exit status or signal, with a bounded termination-notification wait, without
exposing helper logs, narration or filesystem paths. Cancellation/deadline and
owned-process cleanup still apply.

| Check | Result and scope |
| --- | --- |
| Provider startup only | The actual project-owned Python interpreter ran `-I -B runtime/kokoro/provider.py` with stdin EOF: exit 0, one protocol-v1 hello, no stderr. No prepare/synthesize request, MLX import, model load or inference was performed. |
| Scheme / project metadata | Shared scheme XML parses and explicitly has `LaunchAction enableGPUValidationMode="1"` (disabled). Xcode project and app plist pass `plutil -lint`. Xcode GUI interpretation remains an operator check. |
| Focused native build/tests | `CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" swift test --cache-path "$PWD/.build/swiftpm-cache" --disable-sandbox --skip-update --filter 'speechHelper\|kokoroMissingRuntime'`: **8 Swift Testing tests passed** (21 individual cases; no skips). Debug shared core, app, CLI and tests compiled. Five new cases verify startup/preparation/synthesis exit codes, signal termination and a still-running helper that closes stdout, with bounded cleanup and no request text/path in errors. Existing reuse, numeric speed, unsafe outputs, cancellation/deadlines/owned descendants, missing runtime/confinement and synthetic SQLite→M4A/RSS checks passed. User-cache/deprecated-option warnings remain; no Swift source diagnostic. Log: ignored `var/validation/2026-10-03-speech-crash/swift-focused.log`. This is synthetic protocol/pipeline evidence, not actual MLX inference. |
| Preservation | No provider, runtime setup, dependency/model pin, Python reference, customized configuration, saved fixture/published data, cache/download policy or service enrollment change. `.runtime/`, `models/` and generated `var/` remain ignored. |
| Outstanding acceptance | Actual GUI/CLI Kokoro completion, M4A listening, repeat/recovery, Canvas and full native/Release gates remain open. No change to linkd/Intents or status-item layout warnings is claimed. |

See the [step-by-step Xcode retry](KOKORO_PROVIDER.md#speech-helper-aborts-under-xcode-metal-api-validation).

## October 3 source-quality and whole-number speech-speed corrections

The operator reported duplicated captions, images in cleaned HTML, apparent
apostrophe/quote mojibake in two private exports, footnote markers in narration,
and `Speech speed must be a number` during CLI speech generation. The operator
also reports fixture steps worked until CLI generation, with tones heard in mock
mode. This does not establish Kokoro speech completion/listening acceptance.

Read-only inspection of the two supplied snapshots found UTF-8 source/cleaned/JSON
bytes with correct Unicode and no literal `â€™` sequences. Both original sources
declare UTF-8; cleaned fragments had no charset metadata. The reported display is
consistent with interpreting UTF-8 through a legacy charset, rather than evidence
of damaged stored text. Browser rendering was not inspected by the agent. The
headlight source DOM contains two copies of its caption, including lightbox
markup; both survived into the old cleaned HTML and JSON. The existing narration
normalizer had not removed that duplicate. The blog export retained five linked
footnote references and their definitions.

The speech failure was localized to numeric checkpoint decoding: `.number(1.0)`
encodes as JSON `1`, which `SettingValue` decodes as `.integer(1)`. The helper's
speed guard accepted only `.number`. Numeric settings now accept either form,
without accepting strings/booleans or relaxing speed bounds. GUI/CLI profile
selection uses the same numeric interpretation. The Settings mode picker now
shows both Mock tones and Kokoro speech in a segmented control.

Cleaned exports now declare UTF-8, remove inline media, preserve caption semantics
and deduplicate adjacent equal captions. Semantic blocks retain marker text plus
optional spoken-text/reference/definition fields. Narration resolves marked local
footnotes/citations once after the first referring block, with Footnote/End
Footnote cues, retaining multi-paragraph note bodies and source-block provenance.
Unresolved marked references produce notices; ordinary numbers/superscripts and
unmarked citations are preserved. Referenced definitions removed by Readability
can be recovered from the original source; unrelated source notes are not added.
Decorative symbol separators are omitted from speech. Version fingerprints changed;
valid published checkpoints retain their saved versions/artifacts, while unfinished
work still validates current versions/fingerprints.

| Check | Result and scope |
| --- | --- |
| Focused native build/tests | `swift test` with project-local caches, `--disable-sandbox --skip-update`, filter `SourceReviewTests\|sourceExtraction\|semanticBlocks\|narrationHas\|speechHelper`, and explicit `VOICERELAY_REVIEW_FIXTURES`/`VOICERELAY_REVIEW_OUTPUT`: **28 Swift Testing tests passed, no skips**. Debug shared core, app, CLI and tests compiled. Tests include UTF-8/full HTML, media removal, adjacent-caption-only deduplication, number/star/dagger/citation markers, multi-paragraph notes, backlinks, ordinary numbers/superscripts, unresolved notes, discarded appendix recovery, older optional-field decoding, numeric speed JSON round trips, invalid speeds and existing helper cancellation/provenance checks. Full native suite and Release were not run. |
| Private saved-source regression | Both explicitly selected snapshots were reprocessed offline, with no fetch. Refreshed exports are in the project's ignored `var/article_snapshot_fixed/` under new UUIDs. Both have UTF-8 metadata, zero inline images and no literal mojibake apostrophes. The headlight caption occurs once in cleaned HTML and narration (five retained captions total; 60 chunks). The blog export has five Footnote and five End Footnote cues (68 chunks); the cited third note has two paragraphs, its referring marker is omitted from speech, and no backlink arrows are spoken. Original source bytes/mtime stayed unchanged; old exports were not rewritten. Rendering/listening/completeness remain separate gates. |
| Persisted speed / encoder integration | An owned synthetic protocol helper ran through actual native SQLite checkpoint serialization, ffmpeg/ffprobe M4A/RSS publication with speed 1.0, and an idempotent repeat. This is process/pipeline evidence, not real Kokoro speech. |
| Published-version compatibility / recovery | After the last coordinator compatibility change, focused filter `speechHelperNumericSpeedSurvivesPersistedFixture\|speechFingerprintChangesInvalidateUnpublishedAudio\|speechCompatibleCheckpointResumesAndLegacyEpisodeDecodes`: **3 tests passed**, including two fingerprint boundary cases. Published older-version checkpoint/article/narration, M4A and RSS bytes remain unchanged with zero synthesis; unpublished changed-backend work invalidates/rebuilds as required; compatible interruption reuses completed chunks and older episode JSON decodes. Debug app/core/CLI/tests rebuilt. One test overlaps the 28-test run above. |
| Project / preservation | App plist and Xcode project pass `plutil -lint`. No new dependency, pin, runtime/model download, Python-reference/configuration/live feed/audio change or service enrollment. New private exports remain under ignored `var/`. Future local image descriptions are recorded in the plan only. |
| Operator gates | Xcode GUI/segmented-picker and Canvas rendering, browser display of the corrected HTML, source completeness, actual Kokoro CLI/GUI inference and listening remain **unverified by the agent**. Selected network articles still have review/export only; their speech pipeline and durable queue remain pending. Startup layout/linkd warnings are unchanged. |

See the [updated speech instructions](KOKORO_PROVIDER.md#first-user-run-speech-check-in-xcode)
and [caption/footnote policy](SOURCE_REVIEW.md#caption-encoding-and-footnote-policy).
Use a fresh empty speech fixture directory when testing the new build. Actual
MLX/Metal model execution is handed to the operator; the agent's checks use only
synthetic helpers and isolated generated audio.

## October 3 runtime readiness and manual source-review development

Subsequent operator GUI evidence: Reading List articles appeared after selecting
`Bookmarks.plist` through **Choose plist…** and refreshing. The operator reports
that articles did not appear by default. This confirms selected-file discovery
and list presentation under that run's app context. It does not establish
default-path access, access persistence after relaunch, inventory completeness,
source extraction quality or speech acceptance. Opening Articles deliberately
does not refresh; no pre-selection refresh error/path was supplied, so no specific
permission or default-path cause is diagnosed. No source change or new build/test
was performed for this operator-evidence update.

The operator reports that Kokoro setup is now good. The agent subsequently ran
`PYTHONDONTWRITEBYTECODE=1 python3 runtime/kokoro/runtime_setup.py check`:
exit 0 and `ready: true` for `mlx-community/Kokoro-82M-bf16`, revision
`a71e4d38b236d968966a2002c4c895dbd12b1c3c`, in the project's model directory.
This is installed package/asset/provenance readiness evidence; no inference,
Metal allocation, audio generation or listening was performed. It supersedes
the setup-unavailable states recorded below for earlier revisions.

Implemented the first part of Slice 3: shared XML/binary read-only Reading List
parsing and session inventory; one selected bounded ephemeral URLSession fetch;
plain-text semantic/narration review; conservative page inspection outcomes;
explicit private UUID snapshot export; Articles window, inert previews and
diagnostic CLI commands. Exclusions/inventory are session-only. There is no new
durable queue, real-article speech pipeline or live state adoption. The shared
core remains used by both build routes; Xcode source references include the new
view and focused test file.

| Check | Result and scope |
| --- | --- |
| Focused native suite / Debug compilation | `CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" swift test --cache-path "$PWD/.build/swiftpm-cache" --disable-sandbox --skip-update --filter SourceReviewTests`: **13 Swift Testing tests passed**, including parameterized XML/binary, eight response failures, four page inspection outcomes and two cancellation/deadline cases. SwiftPM Debug shared core, app, CLI and test sources compiled. The full existing native suite and Release were not rerun. |
| Discovery fixtures | Synthetic XML/binary nesting, UUID deduplication, distinct UUIDs at the same URL, date/fallback identity, unsafe URL skipping, malformed/deep/oversized refusal, unchanged source bytes/mtime, successful merge and retained absent/excluded entries after a failed read. No actual Safari file opened. |
| Fetch policy and transport fixtures | In-process URLProtocol responses test HTML bytes/provenance, no cache/cookie/credential stores, status/type/empty/encoding/known-length/streamed-size/transport-policy errors and safe diagnostics. Deadline and cancellation pass both before headers and after a partial body; no external socket/network source. Redirect delegate checks exercise per-hop downgrade/credential/limit refusal and header stripping; they do not validate actual live redirect/auth/TLS delivery. |
| Review and private export | Saved synthetic article preserves original/final/canonical provenance and ordered narration. Title heuristics/empty extraction produce inspectable outcomes. Exports preserve raw source bytes/hash, opaque UUIDs, owner markers and 0700/0600 modes; refuse unowned nonempty, symlinked-owner, configured overlap, selected fixture overlap and marked fixture ancestor destinations. Flagged export has no fabricated article. |
| CLI smoke | Built Debug CLI reads checked-in `Fixtures/reading-list.synthetic.plist`: two entries, zero skipped, no source URLs/titles printed, unchanged bytes/mtime. A `file:` review URL returns exit 1 with a fixed diagnostic before creating any destination. CLI smoke uses an isolated temporary working directory. |
| Xcode source/config static checks | `plutil -lint` passes for project, app plist and synthetic plist. Parsed project verifies new app/test compile-phase membership and shared core references, with all compile inputs present. SwiftPM/Xcode dependency pin arrays still match. Installed `xcodebuild -version`: Xcode 27.2, build 27B5028f. No new Xcode bundle build/test or GUI run is claimed; prior manifest/cache restriction is recorded below. |
| Runtime/model and preservation | Readiness check only; no setup or downloads. Existing `.gitignore` retains project-local model/runtime/cache ignores, and `var/` covers suggested review exports. Historical Python, benchmark environment, customized TOML, live database/feed/audio, dependency pins and service registration were not changed. |
| GUI / protected sources / speech / live acceptance | **Not run by the agent.** Xcode bundle/test/Canvas, window interactions, actual Safari hierarchy and app-identity permission, live redirect/auth/ATS behavior, representative short/medium/long source completeness, real Kokoro inference/listening, signed relocation, agent context and delivery remain gates. |

Only existing deprecated `--skip-update` and unavailable user-cache warnings
were emitted by the final SwiftPM check; no Swift source diagnostic remained.
System ATS protections remain enabled; some HTTP sources can be refused even
though HTTP(S) URLs pass the source validator. This limitation is explicit in
the [source-review guide](SOURCE_REVIEW.md), alongside operator-owned checks.
Conservative login/consent/access-title heuristics are not a comprehensive source
classifier. The layout/linkd investigation is unchanged and remains separately
documented; successful compilation does not certify its resolution.

Next operator actions: follow [the step-by-step Xcode source-review checks](SOURCE_REVIEW.md#step-by-step-xcode-checks)
and the independent [Kokoro speech/listening guide](KOKORO_PROVIDER.md#first-user-run-speech-check-in-xcode).
Full Slice 3 completion still requires durable queue/retry implementation and
reviewed-article speech/source-quality evidence. Nothing enrolls a service,
publishes remotely, changes hosting or consumes the Reading List backlog.

## October 3 source-only docopt installation correction

Historical setup-fix evidence. The readiness/setup confirmation above supersedes
this section's then-open installation gates; its original results are preserved.

The operator's latest retry used the already installed Python 3.12.15 and created
`.runtime/kokoro/.venv` successfully. The pinned package stage then stopped because
`docopt==0.6.2` has no usable wheel while setup imposed `--only-binary :all:`.
This supersedes the earlier missing-venv state below; it does not certify the
dependency or model installation.

The lock includes docopt through num2words. PyPI's release metadata lists only
the 25,901-byte source archive, with SHA-256
`49b3a825280bd66b3aa83585ef59c4a8c82f2c8a522dbe754a8bc8d08c85c491`, matching
the existing application lock. Read-only inspection of the corresponding benchmark
lock identifies docopt as the only application-pinned package with no listed
wheels; this does not establish every other wheel's platform compatibility or
availability during an actual clean setup.

Setup now retains `--only-binary :all:` and adds the specific `--no-binary docopt`
exception. It retains `--require-hashes` and supplies the existing hashed lock as
`--build-constraints`, including its setuptools pin, for isolated build dependencies.
No requirements hash, version, global configuration, Swift source, Python reference,
benchmark runtime or live/published data was changed. All build/cache/venv paths
remain project-owned and ignored by the existing `.gitignore`.

| Check | Result and scope |
| --- | --- |
| Offline setup suite | `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s runtime/kokoro/tests -v`: **14 tests passed**, no skips. The production command assertions include the docopt-only exception, hashed requirements, owned interpreter and explicit build constraints. |
| Actual uv source-policy regression | uv 0.11.7 with the already installed managed Python ran against local synthetic source archives, `--offline` and `--no-index`, in separate temporary project-owned venvs/caches. Four cases passed: the old blanket policy refuses the synthetic docopt sdist; the exception builds/installs it and its module/version import succeeds; an unrelated source-only package is still refused; a wrong source hash is rejected. The synthetic backend uses only stdlib and requires no build dependencies. This is policy evidence, not an upstream docopt/setuptools build or real TTS acceptance. All temporary source-policy fixtures were removed. |
| Dependency provenance / scope | Published docopt archive hash matches the existing lock; the inspected benchmark lock lists no wheel for docopt and lists wheels for the other matched pins. No runtime/model/dependency download was performed by the agent. |
| Python source parse | Setup, provider and setup test sources passed `ast.parse` without writing bytecode. |
| Full setup / native / GUI / speech | Full package/model installation, actual upstream docopt build, runtime check, Metal inference and listening remain operator gates. Native builds, GUI and Canvas were not rerun for this Python setup-only change; prior native evidence remains historical. |

Next operator action: rerun `python3 runtime/kokoro/runtime_setup.py setup --download`
from the project root without deleting the interpreter or venv, then run
`python3 runtime/kokoro/runtime_setup.py check` after setup succeeds.
See [the provider guide](KOKORO_PROVIDER.md#storage-and-explicit-setup).

## October 2 managed-Python option conflict correction

The operator's retry successfully installed project-owned CPython 3.12.15, then
failed during virtual environment creation with `--managed-python` cannot be
used with `--python-preference`. The script itself supplied both the CLI flag
and `UV_PYTHON_PREFERENCE=only-managed` in its child environment; this was a setup
bug, not evidence of an incompatible Python download or changed global settings.

The duplicate environment preference has been removed. The explicit managed-only
venv flag, exact Python version, disabled venv downloads, owned install/cache
paths, and explicit venv Python target for package synchronization remain in place.
Inherited uv preferences continue to be stripped. No Swift source, package/model
pin, global configuration, Python reference or published data changed.

| Check | Result and scope |
| --- | --- |
| Actual failure reproduction | uv 0.11.7 returned exit 2 with the same option-conflict error using the old setup environment and `--offline` against an isolated temporary venv target. No download or package installation occurred. |
| Offline setup regression suite | `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s runtime/kokoro/tests -v`: **13 tests passed**, no skips. The new regression uses the actual setup environment, installed uv and already downloaded project-owned Python to create a temporary venv under `.runtime/tmp`, verifies its interpreter resolves to `.runtime/python/cpython-3.12.15-macos-aarch64-none/bin/python3.12`, runs that interpreter with `-I -B`, and confirms version 3.12.15 and the temporary venv prefix. The fixture was removed afterward. No network, MLX, model or dependency installation. |
| Operator installation evidence | Supplied console confirms successful CPython 3.12.15 installation before venv creation failed. The temporary regression also verifies that installed interpreter runs; it does not complete `.runtime/kokoro/.venv` or the pinned dependency/model installation. |
| Native build / GUI / speech | Not rerun for this Python setup-only correction. Prior native build evidence remains historical; full setup, runtime check, Metal inference, listening and Xcode/GUI gates remain open. |

Next operator action: rerun `python3 runtime/kokoro/runtime_setup.py setup --download`
from the project root, retaining the already installed interpreter, then run
`python3 runtime/kokoro/runtime_setup.py check` after setup succeeds.

## October 2 pinned Python download catalog correction

The operator's explicit setup stopped with `No download found for request:
cpython-3.12.15-macos-aarch64-none`, followed by the generic `CalledProcessError`.
The inspected tool is uv `0.11.7` (`9d177269e`, April 15, 2026). Its embedded
catalog lists CPython 3.12.13 for this platform and returns no download for the
selected exact 3.12.15 pin. This local reproduction identifies a catalog mismatch;
it is not evidence that the Python release or MLX packages are unavailable.

The project now supplies a single-entry `runtime/kokoro/python-downloads.json`
to interpreter installation. The published Apple Silicon CPython 3.12.15 archive
URL and SHA-256 were read from the upstream python-build-standalone `20261001`
release asset listing. The script checks the catalog's selected version/platform,
release URL and checksum format before creating runtime directories. It keeps
`--no-config`, project-owned install/cache paths and `--no-bin`; subsequent venv
creation requires the managed interpreter and disables automatic Python downloads.
Failures now report the stage and exit status/timeout without echoing the command.
The Swift backend fingerprint includes the catalog. No package/model/version pin
was relaxed, global tool updated, or Python/Conda configuration changed.

| Check | Result and scope |
| --- | --- |
| Installed uv catalog comparison | Offline `uv python list 3.12.15 --only-downloads --show-urls --output-format json` returned `[]` with the bundled catalog, then exactly `cpython-3.12.15-macos-aarch64-none` with `--python-downloads-json-url` pointing to the local catalog. No interpreter/archive was downloaded. uv routes this release URL through its official `releases.astral.sh` mirror. |
| Offline Python regression suite | `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s runtime/kokoro/tests -v`: **12 tests passed**. Includes the real installed uv's offline catalog parsing, mocked explicit setup command/environment isolation, incompatible metadata refusal before runtime creation, and stage/timeout diagnostics. No MLX imports or downloads. |
| Focused Swift check / Debug compilation | `CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" swift test --cache-path "$PWD/.build/swiftpm-cache" --disable-sandbox --skip-update --filter kokoro`: **one Swift Testing test passed**; Debug shared core, app, CLI and tests built. The test includes catalog fingerprint changes, missing-runtime refusal and escaped-model rejection. User-cache access/deprecated-option warnings remain; no Swift source diagnostic was emitted. |
| Python source parse | `ast.parse` passed for setup, provider and setup tests without writing bytecode. |
| Actual runtime / speech | **Not run.** The project-owned inference interpreter and selected model snapshot remain absent. Archive-byte checksum verification, wheel installation, G2P completeness, Metal inference, listening and Xcode/GUI acceptance remain operator gates. The catalog check does not establish full setup success. |

Next operator action: rerun `python3 runtime/kokoro/runtime_setup.py setup --download`
from the project root, then run `python3 runtime/kokoro/runtime_setup.py check` after
setup succeeds. Existing directories from the failed attempt can remain in place.
See [the provider guide](KOKORO_PROVIDER.md#storage-and-explicit-setup).

## October 2 selected Kokoro development slice

The supplied completed benchmark handoff now selects Kokoro through mlx-audio
Python. [KOKORO_PROVIDER.md](KOKORO_PROVIDER.md) records selection evidence,
project-local storage, protocol/recovery boundaries, and exact operator checks.
This supersedes older engine-selection deferrals below. Historical build/runtime
records remain evidence for their original versions only.

Implemented: public runtime/model/package pins and a hashed standalone lock;
explicit owned setup; project-local interpreter/venv/G2P/model/cache paths;
offline normal use; a serialized supervised protocol-1 `TTSBackend`; explicit
speech CLI and Settings controls; separate tone/speech ownership markers;
chunk and encoded-input fingerprints; older optional-field decoding; named inert
speech preview. The historical Python application, benchmark sources/runtime,
customized configuration, live state/media/feeds, Safari and hosting were not
modified or adopted. No service was enrolled or feed uploaded.

| Check | Result and scope |
| --- | --- |
| Dependency lock export | Offline frozen uv export from the selected benchmark graph succeeded, with the benchmark package/dev/other-engine extras excluded. App setup uses the standalone hashed result, not the benchmark environment. No interpreter/package/model download was performed. |
| Shared native build / suite | `swift test --cache-path "$PWD/.build/swiftpm-cache" --disable-sandbox --skip-update` with project-local module caches compiled the Debug app, CLI and tests; **24 Swift Testing tests passed**. Includes actual ffmpeg validation/encoding plus synthetic backend recovery. No inference engine was loaded. |
| Earlier focused native pass | After adding `-B` to the isolated Python launch, `swift test --filter 'speech\|kokoro'` with the same local-cache/build flags. **Six test functions passed**, with parameter cases for failures, cancellation/deadline and checkpoint changes. |
| Focused behavior | Helper preparation reused once, ordered multiple artifacts and matching provenance, safe error handling, helper crash/restart, traversal/mismatched response rejection, missing runtime/external symlink refusal, bounded deadline/cancel and owned synthetic descendant termination, compatible resume, incompatible unpublished chunk/encoded invalidation, published immutability, old native record decoding, captured explicit voice/speed without live-path overlap, and pre-write escaped chunk rejection passed. These helpers generate tones and are not speech evidence. |
| Offline Python suite | `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s runtime/kokoro/tests -v`: **7 tests passed**. Covers project-local environment/no global cache fallback, missing-runtime no-download behavior, nested external-link preflight, checkpoint SHA/dtype, pins/lock, and safe real-provider control errors without importing MLX. All three Python sources parse. |
| Ignore policy | Six representative model/interpreter/venv/cache paths were ignored using the project's `.gitignore` in an isolated temporary Git repository; source and lock paths remained unignored. VoiceRelay itself is not a Git repository, so no staging/commit was attempted. |
| CLI with no imported profile | A fresh `/private/tmp` speech attempt captured explicit voice/speed and reached the expected missing project-local runtime error (exit 1), rather than a path-overlap error. No speech helper, audio, feed or download was produced; the isolated temporary workspace was removed afterward. |
| Read-only setup inspection | `runtime_setup.py paths` returned only project-owned paths. `check` returned the expected exit 2 with an actionable missing-runtime message; it downloaded/created no runtime/model. |
| Xcode project/static | Project and app plist lint passed; SwiftPM and Xcode dependency pins match. Added core/helper and runtime source navigation without changing deployment target, shared scheme behavior, or diagnostics. |
| Xcode Debug build-for-testing | **Blocked before app compilation.** Restricted manifest diagnostics initially tried an unavailable user cache. A `CFFIXED_USER_HOME` local-cache experiment progressed to manifest sandbox execution, then failed with `sandbox-exec: sandbox_apply: Operation not permitted`. No permission escalation or GUI automation was requested. This is not a Swift source compile failure or a passed Xcode gate. |
| GUI / Canvas / actual speech | **Not run by the agent.** New Settings controls, preview rendering, explicit runtime installation/download, real MLX/Metal inference and listening remain operator checks. No new runtime-warning result is claimed. |

Initial test failures were test-scope issues: the recovery test held a native
writer lock during resume, and the deadline assertion included a delayed async
test-executor resumption under concurrent ffmpeg work. The corrected tests release
the store before resume and measure the actual helper call; final checks above
passed. The underlying process deadlines use monotonic uptime. SwiftPM emitted
user-cache access and deprecated `--skip-update` warnings; the final source build
emitted no Swift source diagnostics.

Ignored logs are under `var/validation/2026-10-02-kokoro/`: `swift-tests.log`,
`speech-focused-final.log`, `python-tests.log`, and the two blocked Xcode logs. The final full native pass also includes the later folder-confinement and explicit-option regressions. The Xcode attempts
also produced unavailable simulator/profile and beta tooling diagnostics; these
do not establish app runtime behavior.

Remaining gates for this change:

- User Xcode Debug build/Test, Canvas, speech Settings/Inspect/Pause/Resume/Repeat/Quit.
- Clean project-owned interpreter/dependency/model installation, including wheel
  availability, G2P completeness and retained license inventory.
- Real speech codec/decode/completeness and listening; this app's own throughput,
  memory and hours-long resource behavior. Benchmark success is independent evidence.
- Actual Metal cancellation, abrupt-parent-loss cleanup, signed/relocatable runtime
  and complete redistribution review; the development runtime is not app-bundled.
- Existing Safari/HTTP, persistent signed agent/XPC/SMAppService/privacy/Keychain,
  backed-up data adoption, delivery/device/hosting acceptance remain future slices.

Next operator action: follow [the Terminal setup and Xcode speech guide](KOKORO_PROVIDER.md#first-user-run-speech-check-in-xcode).

## October 2 fresh native startup run: warning and interaction both confirmed

The operator reports stopping the previous session, clearing the console, and
restarting execution. The new console is therefore evidence from a fresh run,
not continuation of the earlier paused process. It identifies host macOS 27.2
`26B5091g`, `LSUIElement = true`, activation policy 1, and `NSSceneStatusItem`.
All startup creation/label/menu stages return. The layout-recursion warning then
appears before the first logged `MENU will open`; exact click timing is not
supplied, so this ordering does not identify a particular source assignment.

The same log records two menu openings/closings, the direct **Confirm menu
action** marker, **Quit requested from native menu**, and termination cleanup.
This supports successful native menu presentation, action dispatch, and the
normal Quit path in this fresh run despite the warning. It does not certify
VoiceRelay's Settings/Inspect/fixture interactions or live/speech acceptance.

Additional diagnostics: Intents registration code 4 and linkd connection code
4097 persist; a task-name-port failure appears with an unidentified caller.
Each menu opening also logs `makeKeyWindow` against an AppKit
`_NSGlassEffectWindow` whose `canBecomeKeyWindow` is false. The startup source
creates no NSWindow and makes no key-window or task-port calls. The glass-window
messages coincide with native menu presentation, making framework presentation
the stronger lead; no originating stack or specific defect is established.
Apple's [canBecomeKey documentation](https://developer.apple.com/documentation/appkit/nswindow/canbecomekey)
states that attempts to make an ineligible window key are abandoned. The
subsequent action and Quit markers show that these messages did not block the
observed interactions; they are not blanket evidence of harmlessness in all runs.

Diagnostic disposition: the layout mechanism is localized and independently
reproduced in AppKit-only startup. Keep the production UI and proceed with
development while tracking these runtime warnings and retesting after approved
updates. There is no demonstrated benefit from project recreation or native UI
replacement, and no additional unchanged startup experiment is required now.
Exact internal cause, beta-only attribution, and a warning-free release remain
unresolved. Only documentation and the local feedback draft were updated; no
new build/tests, automated GUI, submission, permission/service change, or live-data
operation occurred.

## October 2 native menu-bar startup reproduces layout recursion

The operator hit `_NSDetectedLayoutRecursion` in `StatusItemStartupRepro` and
supplied `thread backtrace -c 100`. Stop reason is breakpoint 1.1 on the main
thread. Frames 81–85 name the native startup diagnostic's application entry and
`NSApplication.run`; no SwiftUI frame appears. The source imports AppKit only,
creates no ordinary window, and has no VoiceRelay/core/data dependency.

Comparison with the prior MenuBarExtraRepro capture confirms that frames 0–80
match exactly after removing addresses. In particular, frames 40–45 connect the
status-item scene and set its display identifier. Frames 14–18 change a view
frame during layout and post its notification; the AppKit observers request
window placement/layout (5–13), reentering `layoutSubtreeIfNeeded` (0–4).

Conclusion: this warning does not require SwiftUI, VoiceRelay's panel, or the
pipeline. It reproduces in a minimal native AppKit menu-bar-only startup control
with the same immediate framework mechanism. Replacing MenuBarExtra with a
native status item is therefore not a demonstrated remedy. The contrast with
the clean interactive native controls points toward app policy/startup/window
conditions; those factors changed together and are not individually isolated.
An AppKit/runtime defect or environment interaction is the stronger lead, but a
beta-only regression and the exact internal receiver/cause are not established.

The supplied attachment contains the backtrace only, with no StartupProbe console
markers or last-action report. It identifies asynchronous scene-connection work,
not a precise source assignment or whether the operator had clicked the item.
Post-continue menu action, Quit, and responsiveness remain open. This debugger
stop is not a crash. Current Intents/linkd behavior is not established by this
stack; the earlier native logs reproduced those messages without layout warnings.

Updated the diagnosis guide and prepared a local
[Apple feedback draft](../Diagnostics/StatusItemRepro/APPLE_FEEDBACK_DRAFT.md).
No feedback was submitted. Only documentation changed; no new build/core test,
GUI automation, permission/service change, or live-data operation occurred.
The existing successful Debug build/signature evidence remains separate from
operator runtime reproduction and remaining functional acceptance.

## October 2 AppKit variable-width result and native startup control

The operator's next console records a fresh baseline on macOS 27.2 build
`26B5091g`, variable-width native item creation, runtime class `NSSceneStatusItem`,
text, waveform, menu attachment, Quit, and cleanup. No layout-recursion warning
appears in this excerpt. Unlike the square-width run, no ignored mode-change
marker appears. Both native width modes have now completed those recorded stages
without an observed layout warning. Neither excerpt contains menu-opening or
menu-closing markers; actual menu presentation remains unconfirmed by the logs.
Intents/linkd connection/registration errors persist in the variable-width run.

These results weaken an explanation based solely on item width, native waveform
assignment, or the `NSSceneStatusItem` runtime class. They strengthen a lead in
SwiftUI scene/label handling or differences in startup timing and app policy.
The native controls create the item interactively after an ordinary window has
opened; the SwiftUI controls are `LSUIElement` apps creating their item at startup.
No specific framework defect, beta OS cause, or production fix is established.

Added isolated `StatusItemStartupRepro` source, target, and shared scheme. It uses
AppKit only, `LSUIElement = YES`, a variable-width item created during launch,
the waveform image, and a native menu, with no ordinary window. A **Confirm menu
action** item emits a direct selection marker so menu interaction can be observed
without relying on menu-delegate callbacks. This narrows remaining differences;
its exact callback timing and native label/menu content still differ from SwiftUI.

Agent validation on Xcode 27.2 beta `27B5028f` / SDK 27.2: arm64 Debug build and
strict signature verification passed. Generated plist confirms the intended
executable, isolated bundle identifier `org.voicerelay.diagnostics.startup`,
minimum macOS 27.0, and `LSUIElement` enabled. Binary inspection found no direct
SwiftUI or VoiceRelayCore dependency. All preexisting diagnostic project objects
were preserved except required group/target membership additions. All 31 files
captured in the current production source/test/packaging/notices/main-project
baseline retain their hashes. No production behavior changed or core tests reran.

The new scheme's Build/Run/Profile bindings match its target and product. Static
inspection also found an existing operator-edited Run override in
`MenuBarExtraRepro.xcscheme`: it builds MenuBarExtraRepro but launches
StatusItemLifecycleRepro. That setting was preserved. Source/console identity is
used for these results, rather than inferring the executable from the scheme name.
Other Run bindings match their named targets.

Build log: `/private/tmp/voicerelay-layout-startup-build.log`. Sandbox logging/
CoreSimulator service diagnostics and skipped App Intents metadata extraction
were present; no Swift source warning/error was observed. Release and the new
probe's GUI/runtime behavior remain unrun. No GUI automation, service enrollment,
permission change, or live-data operation occurred. The manual startup comparison
is documented in the [diagnosis guide](../Diagnostics/StatusItemRepro/LAYOUT_DIAGNOSIS.md).

## October 2 AppKit square-width operator result

The operator reports completing the lifecycle diagnostic without hitting the
layout-recursion breakpoint. The supplied console contains the AppKit probe's
baseline markers and host version 27.2 build `26B5091g`. It records square-width
item creation, runtime class `NSSceneStatusItem`, text assignment, waveform
loading/assignment, native-menu attachment, Quit, and owned-item removal during
termination. No layout-recursion warning appears in the supplied log. The
operator also reports no debugger prompt; no warning backtrace is needed when
the debugger has not stopped.

The log includes `Ignored: restart the app to change creation mode` after
square-width creation. Source inspection confirms this guard leaves the existing
item unchanged. This run does not exercise variable-width creation; that requires
a fresh process choosing 1b first. The operator's general report says all tests
completed, but the excerpt has no `MENU will open`/`MENU did close` markers, so
actual menu presentation is not established by these markers. Preserve the
reported outcome while keeping that instrumentation limit explicit.

This provides a useful negative control: square-width native creation and the
recorded label/menu updates did not reproduce layout recursion in this run,
although the runtime item class matches the `NSSceneStatusItem` path in the
SwiftUI trace. The class alone is not sufficient to explain the warning. SwiftUI
scene/label sizing, startup timing, activation policy, and ordinary-window
presence remain differences to isolate; no specific defect or fix is proven.
Intents/linkd errors still occur in this run without an observed layout warning,
adding evidence to investigate those messages separately.

Only documentation was changed for this result. No new build, core test, GUI
automation, permission change, or production/live-data operation was performed.
The next narrow operator check is a fresh `StatusItemLifecycleRepro` run choosing
variable width first, then label, waveform, menu attachment and opening, with
console markers retained. The production UI remains unchanged.

## October 2 fresh symbolic-breakpoint capture: SwiftUI control

The operator supplied a new `thread backtrace -c 100` capture. The main thread
stopped at breakpoint 1.1 in `_NSDetectedLayoutRecursion`, confirming the recreated
breakpoint catches the warning path. Frame 86 identifies the executable as
`MenuBarExtraRepro.debug.dylib` and source `MenuBarExtraReproApp.swift`; frames
82–84 show SwiftUI startup. This is evidence from the SwiftUI window-style
control, not a run of the new AppKit-only `StatusItemLifecycleRepro` probe.

Frames 40–45 show status-item scene connection. During the original layout,
frames 14–18 show a view frame change and frame-change notification; AppKit
observers then reenter window placement and `_layoutViewTree` (5–13), requesting
layout again (0–4). This reproduces the earlier mechanism with a slightly
different inner window-layout path. The attachment contains no `[LayoutProbe]`
markers, last-action report, or subsequent GUI result. A breakpoint stop is not
evidence of a crash. Native item creation without SwiftUI remains untested.

Static reinspection confirms all four shared diagnostic schemes bind Run to
their matching target, product, and single intended source file. No source or
project changes, new build, automated GUI execution, or live-data operation were
needed for this analysis. The next operator check is explicitly
`StatusItemLifecycleRepro → My Mac`, expecting an ordinary control window and
`[LayoutProbe] BASELINE` messages before any status item is created.

## October 2 layout localization and AppKit lifecycle probe

Reanalysis of the operator's existing backtrace localizes the recursion to
status-item scene connection: AppKit layout changes a view frame, posts its
frame-change notification, and an AppKit observer requests window frame/display
work that reenters layout. The chain contains no VoiceRelay callback beyond
startup. Receiver identity and the underlying trigger remain unconfirmed; this
is not certification of an Apple bug or a root-cause fix. Intents/linkd remains
a separate diagnostic. The operator reports Thaw installed but currently stopped;
there is no evidence that it caused this warning.

Added the isolated `StatusItemLifecycleRepro` AppKit-only diagnostic target,
shared scheme, and [manual diagnosis guide](../Diagnostics/StatusItemRepro/LAYOUT_DIAGNOSIS.md).
The user controls bare-item creation (square or variable width), text, waveform,
menu attachment, and menu opening separately. Console markers and a symbolic
breakpoint are intended to identify the first triggering stage. An ordinary
window provides a baseline before any status item exists. No production source
or UI behavior was changed.

Current read-only environment inspection: Xcode 27.2 beta build `27B5028f`, SDK
27.2, host macOS 27.2 build `26B5091g`. The new target's arm64 Debug build passed
using isolated DerivedData at `/private/tmp/voicerelay-layout-lifecycle`; strict
signature verification passed. Its generated plist has the intended executable,
minimum 27.0, and no `LSUIElement`/`LSBackgroundOnly` flags. Binary inspection
shows no direct SwiftUI or VoiceRelayCore dependency. All four diagnostic scheme
bindings passed static checks, and existing project objects were preserved
apart from required membership additions. All 34 captured production-file hashes
remained unchanged. No core tests were rerun for this isolated diagnostic addition.

Build log: `/private/tmp/voicerelay-layout-lifecycle-build.log`. Build-tool sandbox
service/cache diagnostics and skipped App Intents metadata extraction were
present; no Swift source warning/error was observed. Release for this new probe,
GUI launch, breakpoint capture, and runtime warning comparison remain unrun.
No automated computer use, permission change, service enrollment, or live-data
operation occurred. Existing production interaction, speech, and live acceptance
gates remain open as recorded below.

## October 2 independently created default-app control

The operator reports manually creating and running a fresh Hello World macOS app
in Xcode with its default Swift code. The supplied excerpt reproduces the Intents
process-instance registration code 4 message and `com.apple.linkd.autoShortcut`
connection/registration code 4097 with retries. This project was created by the
operator independently of VoiceRelay and the agent-created diagnostic project.
Its source, settings, exact SDK/build versions, and GUI behavior were not
independently inspected; this is operator-reported control evidence.

This establishes that these Intents/linkd messages can occur without VoiceRelay's
implementation or its custom project wiring. A shared framework/runtime,
Xcode-launch environment, or per-user/system-service condition is the stronger
lead. It does not identify which component is at fault or confirm the beta OS
as the cause. Recreating VoiceRelay's project or changing its pipeline is not
supported as a remedy for these reproduced messages.

The supplied Hello World excerpt does **not show layout recursion** or the
task-name-port line. That is an observation about the excerpt, not certification
that neither can occur during the app's full lifetime. Keep the two original
warning categories distinct: Intents/linkd reproduces in the default app, while
the prior status-item backtrace and both menu-bar-style excerpts remain the
evidence for the layout warning. A MenuBarExtra/status-item lifecycle issue
remains a plausible layout explanation, separate from the Intents registration
failure; no common cause is established.

No new source/build/test, GUI automation, permission change, or live-data operation
was performed for this record. Retain the current production UI and tracked
runtime-diagnostic disposition while validating actual behavior. The default-app
result does not substitute for remaining VoiceRelay interaction or live gates.

## October 2 Xcode 27.2 beta and reboot retest

The operator reports installing/testing Xcode 27.2 beta, rebooting the Mac,
successfully building VoiceRelay, and obtaining another console excerpt. The
configuration, exact Xcode build number, SDK, and current macOS build number were
not supplied. This is operator-reported build/runtime-log evidence; no agent
build or environment inspection was performed for this retest.

The excerpt still contains the Intents/process-instance registration code 4
message, `com.apple.linkd.autoShortcut` connection/registration code 4097 with
retries, and the AppKit layout-recursion warning. The task-name-port line from
the earlier diagnostic-app excerpts is not shown here; those were different
applications/runs, so this does not establish that it was fixed. No termination
line or new stack is supplied. Fresh Settings/Inspect/fixture/Quit acceptance is
not established by this excerpt; prior visible-panel evidence remains historical.

Outcome: this Xcode update plus reboot did not eliminate the two original warning
categories in the reported VoiceRelay run. It weakens an explanation limited to
the older Xcode 27.0 build or a transient condition cleared by reboot. It does not
identify the originating component, confirm a macOS beta defect, distinguish the
update's effect from the reboot's effect, or prove that the newer run has the
same internal call sequence as the earlier backtrace. The two independent style
diagnostics have not been separately reported under Xcode 27.2 beta.

Retain the current UI and tracked-diagnostic disposition, conditional on normal
interactive operation. Keep build success, warning presence, functional GUI
acceptance, and core/live acceptance separate. The next useful development work
is unchanged; repeating the same rebuild/reboot without a new observation is not
a further diagnostic result. No source, project setting, dependency, service,
permission, or live-data change was made in response to this retest.

## October 2 operator menu-style results

The operator supplied console excerpts labeled `MenuBarExtraReproApp` and
`MenuStyleReproApp` after running the comparison. Both contain the following:

| Diagnostic | `.window` excerpt | `.menu` excerpt |
| --- | --- | --- |
| Asynchronous process-instance registration / Intents message | Present | Present; the excerpt starts midway through the registration message |
| `com.apple.linkd.autoShortcut`, Cocoa code 4097, retries | Present | Present |
| `layoutSubtreeIfNeeded` / layout recursion warning | Present | Present |
| Unable to obtain a task name port right, kernel failure 0x5 | Present | Present |

The `.menu` excerpt is truncated at its beginning and end. Neither excerpt
includes timestamps, an action marker separating launch from menu opening,
the actual executable/debugger configuration, or an explicit open/Quit result.
They establish the presence of these messages in the operator-labeled runs;
they do not certify every GUI control, absence of a crash outside the excerpt,
or the warning's precise trigger. Earlier operator evidence of a visible
VoiceRelay panel and reported local fixture completion remains valid.

Conclusion: the native `.menu` comparison did not eliminate either original
warning category in these runs. The symptoms are not exclusive to window-style
presentation or the richer VoiceRelay panel. This strengthens the shared
MenuBarExtra/AppKit/runtime lead without establishing a specific OS defect,
the beta OS as the cause, or a causal relationship between Intents and layout.
There is no demonstrated warning-related benefit from changing the production
panel to a native menu. Retain the current window-style VoiceRelay UI, track the
diagnostics, and retest the same schemes after future approved updates.

The task-name-port line is an additional process-access diagnostic. Apple's
[`es_event_get_task_name_t` documentation](https://developer.apple.com/documentation/endpointsecurity/es_event_get_task_name_t)
describes the corresponding class of task-port acquisition. These particular
logs do not identify its caller, target-process role, or functional consequence.
Source searches found no direct task-port API calls in VoiceRelay or the two
menu diagnostics. No permission/signing changes or process inspection were
performed in response to that line.

This update records operator evidence only. No new code, build, suite run, GUI
automation, service reset, or live-data operation was performed. The style
experiment's warning comparison is now recorded; per-run launch/click timing,
responsiveness/Quit results, Canvas, and the remaining VoiceRelay interaction
checks remain separate acceptance observations.

## October 2 menu-style experiment

The operator chose continued development with runtime warnings tracked, a separate
native-menu experiment, and retesting after future OS/Xcode updates. They identify
their installed macOS as a beta used for development. That is a possible
contributor, not a confirmed explanation for either warning category.

`Diagnostics/StatusItemRepro/MenuStyleReproApp.swift` now defines an independent
`MenuStyleRepro` app and shared Xcode scheme. It uses explicit `.menu` style,
ordinary native menu items, the waveform label, and a Quit action. It imports no
VoiceRelay core, loads no data/configuration, and performs no processing. A named
inert content PreviewProvider is source-local; its Quit action does nothing.
The window-style diagnostic and the VoiceRelay production UI retain their source.
Because native menu items replace fixed-width panel content, the experiment
compares style plus presentation and cannot prove a modifier-only cause.

Inspection found the saved `MenuBarExtraRepro` scheme's Run action pointing at
`WindowRepro.app`, although its Build action targeted MenuBarExtraRepro. The Run
product/target reference was corrected to MenuBarExtraRepro. Its user-selected
unchecked **Debug executable** setting was preserved. This mismatch limits the
interpretation of earlier per-scheme runtime comparisons; it is a diagnostic
launch configuration issue and does not establish the cause of VoiceRelay's logs.
The guide explicitly checks the intended executable and enables the debugger
consistently for the two warning-comparison runs.

| Check | Result and scope |
| --- | --- |
| Project/scheme structure | `plutil -lint` passed. All three targets compile exactly their own source file, and all Build/Run/Profile references match their target/product. No package dependencies are present. |
| MenuStyleRepro Debug | `xcodebuild` passed for arm64/My Mac with temporary DerivedData/module-cache directories and no escalation. |
| MenuStyleRepro Release | The same targeted build passed in a separate temporary DerivedData/module-cache directory. This is a diagnostic Release build, not a VoiceRelay Release gate. |
| Built artifacts | Both Debug/Release strict signature checks passed. Generated plist and Mach-O checks confirm minimum/SDK 27.0, the intended executable/bundle identity, LSUIElement=true, and no LSBackgroundOnly flag. |
| Final source diagnostics | Neither final build emitted a Swift source warning/error. Both emitted the build-tool warning **Metadata extraction skipped, no AppIntents.framework dependency found**. This is separate from runtime linkd registration/connection errors. The restricted build environment also logged unavailable Simulator/logging-service diagnostics; both macOS builds completed. |
| Preservation | SHA-256 checks confirm all 40 sampled existing source/test/notice/packaging/main-project/pin/sample-config and baseline diagnostic files remain unchanged. The intentionally edited diagnostic project/scheme and documentation are outside this unchanged set. No live data or Python reference was written. |
| Runtime and Canvas | Not run by the agent. Menu opening/Quit, warning comparison, and Canvas rendering remain operator checks. No change in runtime warnings is claimed. |

The first Debug attempt using `#Preview` failed when the restricted environment
could not sandbox the compiler macro plugin (`sandbox-exec: sandbox_apply:
Operation not permitted`). The new diagnostic uses the supported PreviewProvider
form instead and both final builds passed. No compiler security option was
disabled and no additional permissions were requested. Existing VoiceRelay
previews were not changed. The core suite was not rerun for this isolated UI
diagnostic addition; focused target/project checks were used.

Final build logs are temporary evidence:
`/private/tmp/voicerelay-menu-style-debug-build.log` and
`/private/tmp/voicerelay-menu-style-release-build.log`. The initial macro-failure
log is retained at `/private/tmp/voicerelay-menu-style-debug-preview-macro-build.log`.

See the [manual comparison and GUI checklist](../Diagnostics/StatusItemRepro/README.md).
It records launch/click warning triggers per style, required debugger settings,
Settings/import/inspection, stable UUID and zero synthesis on repeat, pause/resume,
and normal quit/relaunch. If the small fixture finishes before Pause can be used,
that gate must be reported as not exercised. Future update comparisons retain
versioned observations. No update, automation, service reset, or live cutover is
performed by this experiment.

## October 2 launch investigation

### Operator follow-up: interface now visible

The operator subsequently reports that both requested launch checks work properly
and confirms that VoiceRelay appears in the menu bar; the initial absence of an
ordinary startup window was a discoverability misunderstanding. The supplied
screenshot shows the VoiceRelay panel with **Fixture published locally**,
**Validated M4A (mock tones)**, and **Current — isolated RSS**. This is operator
GUI evidence of the visible panel and reported fixture completion, not independent
inspection of that run's files, human speech acceptance, or acceptance of every
control. The operator continues to observe the console warnings. A separate
warning matrix for every scheme/launch method was not supplied.

Current disposition: retain the Intents/linkd messages and the supplied AppKit
layout trace as nonblocking runtime diagnostics under investigation, given the
now-working interface. There is no confirmed Apple diagnosis or documented fix
for these exact messages on this installed OS/Xcode combination. Reproduction
outside VoiceRelay and the AppKit-only portion of the layout trace weaken the
project-retrofit hypothesis; they do not prove a particular system defect.

Focused source inspection again found no AppIntents/AppShortcut registration,
process-instance-registry call, or direct AppKit layout call/override. The UI path
most directly related to the supplied layout trace is
`MenuBarExtra(...).menuBarExtraStyle(.window)` in
`Sources/VoiceRelayApp/VoiceRelayApp.swift`. Settings and inspection activation
calls are explicit button actions; no such action appears in the supplied launch
trace. Automatic framework registration is still an inference for Intents/linkd,
not a diagnosed application call site. AppKit documents that it calls
[`layoutSubtreeIfNeeded`](https://developer.apple.com/documentation/appkit/nsview/layoutsubtreeifneeded())
automatically before drawing constraint-based views. The
[similar Apple Developer Forums thread](https://developer.apple.com/forums/thread/806471)
does not provide a confirmed root-cause fix; its Apple DTS response discusses
console filtering, which changes visibility rather than behavior.

For that operator follow-up, no application or Xcode settings change was made to
suppress the messages, and no new build/test was run for its documentation-only update. Settings/import,
inspection, cancellation/resume, repeated fixture runs, and normal quit remain
manual interaction gates. If a visible defect appears, capture its own trigger
and stack. A minimal `.menu` style comparison was proposed as a further isolation
step; its subsequent implementation is recorded above and is not a verified fix. Any comparison with
future organization-approved OS/Xcode updates must retain the observed versions
and results; no fixed release is identified.

### Initial report and read-only checks

The initial October 2 report described the same Intents/linkd and layout warnings
in the prototype apps, with no windows appearing. Visible operation had not passed acceptance.
The absence of a startup window is expected for VoiceRelay and MenuBarExtraRepro,
but each must still expose a usable waveform menu-bar panel. WindowRepro must
present an ordinary window. The supplied console excerpt alone does not establish
which executable ran, whether execution was paused, or whether a menu item appeared.

Read-only inspection of
`/path/to/home/Library/Developer/Xcode/DerivedData/StatusItemRepro-dwefklujjgzmkjdbwdsyitmrponz`
found only `Debug/MenuBarExtraRepro.app`; inspected build/run manifest records name
MenuBarExtraRepro. No WindowRepro bundle was present in that project's products.
This does not rule out a launch from another location. The ordinary-window runtime
comparison remains unverified. Both saved shared schemes point to their matching
target/product, launch automatically in Debug, and attach LLDB. No concrete project
wiring defect was found. The saved main-project breakpoint file contains no entries;
this does not establish current debugger state or breakpoints elsewhere.

The permitted command-line environment still reports macOS 27.2 (26B5091g) and
Xcode 27.0 (27A266a). The previously compiled diagnostic bundles remain in
`/private/tmp/voicerelay-status-diagnostics/Build/Products/Debug`. Both passed renewed
`codesign --verify --strict --verbose=2` checks. Both specify minimum/SDK 27.0;
WindowRepro has neither LSUIElement nor LSBackgroundOnly set, while MenuBarExtraRepro
has LSUIElement=true and no LSBackgroundOnly flag. These are artifact checks,
not runtime results. No new compilation, test suite, or GUI run was performed.
A read-only process listing was denied by the sandbox; no process-state conclusion
is claimed and no permission escalation was requested.

The [manual guide](../Diagnostics/StatusItemRepro/README.md) now starts with a Finder
launch of the prepared WindowRepro, an Xcode run with **Debug executable** unchecked,
and a debugger-attached comparison if the first two work. The operator will report
window/Dock behavior, any launch alert, and Running/Paused status. Missing UI must
not be dismissed as console noise. No application behavior, project settings, live
data, or system services were changed speculatively.

## Minimum version update

The operator reported a successful Xcode build, with a warning that the app's
`LSMinimumSystemVersion` of 14.0 was below the effective deployment target of 14.6.
The build configuration was not specified. This is operator-reported build evidence,
not a GUI, Canvas, test, resource, or signing acceptance result.

At the user's request, the package platform, project Debug/Release deployment
settings, app target Debug/Release overrides, and bundle minimum now specify
macOS 27.0. The app overrides no longer use Xcode's recommended deployment target.
`plutil -lint` passed for project and bundle metadata. A parsed-settings check
confirmed 27.0 for app, CLI, and tests in Debug/Release, explicitly or by project
inheritance, plus the matching bundle/package minimums. Direct manifest type-checking
passed with Swift tools 6.2 API availability and a permitted temporary module cache.
No app rebuild was performed by the agent for this change. The operator subsequently
reported a successful Xcode build without compile errors after the minimum-version
update. The configuration was not specified, and runtime console warnings persist.

## Operator runtime diagnostics under investigation

The operator supplied console messages about process-instance registration and
`com.apple.linkd.autoShortcut` connection errors, a layout recursion warning, and
`Debug session ended with code 9: killed`. This does not identify the cause of
termination or establish that the layout warning caused it.

An earlier operator report confirmed a build without compile errors and repeated
the registration/connection and layout warnings, with no termination line in the
excerpt. That report alone did not establish GUI or fixture acceptance; the
October 2 follow-up above provides the subsequent visible-panel evidence.

The installed SDK's `FoundationErrors.h` defines code 4097 as
`NSXPCConnectionInterrupted`. The repeated connection/registration messages are
retries involving the same `com.apple.linkd.autoShortcut` service, rather than
distinct pipeline-stage failures. Their origin in automatic framework registration
is a working inference from the log and absence of application AppIntents code;
the underlying service failure has not been diagnosed. The layout warning is a
separate nested-layout diagnostic. The operator has now supplied its stack.

Source inspection found no AppIntents/AppShortcut registration, AppKit layout
override, or direct `layoutSubtreeIfNeeded` call. The app uses SwiftUI MenuBarExtra,
Settings/window opening actions, and explicit modal file selection. A framework
call stack was obtained before choosing a layout fix. No speculative UI change or
system-service reset was made.

The supplied backtrace localizes the immediate recursion to status-item scene
initialization inside AppKit:

- Frames 43–49: `NSStatusItem`, `NSSceneStatusItem`, and the status-item variant
  scene delegate connect/configure the status-bar item.
- Frame 21 begins `NSView layout`; frames 18–20 update view geometry, then frame
  17 posts a frame-change notification.
- Its observer calls `NSWindow _setFrameCommon:display:fromServer:` at frame 10.
  Display then requests `layoutSubtreeIfNeeded` at frame 4 while the original
  layout is still active, reaching `_NSDetectedLayoutRecursion` at frame 0.
- No VoiceRelay layout/action callback appears in that sequence. The only shown
  application frame is `main` at frame 89, beneath SwiftUI's application entry.

For this VoiceRelay trace, the strongest inference is an AppKit status-bar
initialization issue in the MenuBarExtra lifecycle. The trace does not prove a
specific OS defect or rule out every influence of declarative view configuration. It provides no evidence of
a pipeline failure or a faulty application `layout` override. The displayed stop
reason is debugger instruction stepping; this backtrace is not a crash report.
The separate Intents/linkd service issue remains unresolved.

Manual next check: disable the diagnostic symbolic breakpoint and continue. Check
menu opening, Settings/inspection, and the isolated fixture explicitly. If they
work without visible layout defects or spontaneous termination, retain this as a
nonblocking runtime warning pending framework/minimal-reproduction investigation.
Record whether Xcode Stop was pressed before the earlier code 9. If termination
was spontaneous, inspect the matching app report's exception and termination reason.
GUI/runtime acceptance remains pending until the operator reports those checks.

Reproduction steps used for the layout stack: open the Breakpoint navigator (⌘8),
click **+ → Symbolic Breakpoint**, enter `_NSDetectedLayoutRecursion` as the symbol,
and run again. If the breakpoint is hit, enter `bt` in the debugger console and
retain the output plus the action that triggered it. Leave the Library field empty.
No desktop automation is required. A similar warning has been reported with
AppKit-only stacks, including status-bar contexts, on
[Apple Developer Forums](https://developer.apple.com/forums/thread/806471);
those reports do not establish the root cause in VoiceRelay.

## Xcode project audit and independent diagnostics

The project-recreation hypothesis was checked against the current project and
the operator's built Debug artifacts in the observed VoiceRelay DerivedData
directory. No concrete wiring defect was found:

- App, CLI, and test targets each compile their intended entry/test source once
  and each link the local `VoiceRelayCore` package product once. The app does not
  separately compile a second copy of the core.
- The shared scheme launches the app target. Root and workspace dependency pins
  match. Debug/Release deployment settings are 27.0, explicitly or by inheritance.
- The built app uses `org.voicerelay.prototype`, `VoiceRelayApp`, LSUIElement=true,
  minimum macOS 27.0, and SDK macosx27.0. Its debug dylib's load command also
  records minimum/SDK 27.0. App Sandbox is disabled as configured.
- The app's core bundle is present. Its fixture is at
  `Contents/Resources/VoiceRelay_VoiceRelayCore.bundle/Contents/Resources/article.html`,
  the normal macOS bundle layout, and matches the saved source fixture exactly.
  The generated `Bundle.module` accessor checks the app's resource directory.
  All packaged acknowledgements match source. Strict signature verification passed;
  verbose signing inspection identifies the local signature as ad hoc.

The Xcode-built Debug CLI was executed in a new owned temporary workspace with
no implicit `config.toml`. Its first fixture run published one episode from seven
chunks. The second synthesized zero chunks. Read-only SQLite/hash checks confirmed
one episode, unchanged identity/publication date, PUBLISHED state, and identical
M4A/feed bytes. This is new validation of the Xcode-built CLI and shared pipeline;
it does not validate app GUI behavior or live speech/delivery. No live data was used.

A separate dependency-free project now exists at
`Diagnostics/StatusItemRepro/StatusItemRepro.xcodeproj`. `WindowRepro` is an ordinary
SwiftUI window control; `MenuBarExtraRepro` creates only a waveform status item with
window-style content. Neither imports VoiceRelay, uses its package/custom plist,
reads a profile, or starts work. Both use Xcode-generated Info.plists and separate
diagnostic identifiers.

Both Debug schemes built successfully with `xcodebuild`, temporary DerivedData and
module-cache directories, macOS 27 SDK, and no permission escalation. Both bundles
passed strict signature verification and minimum-version checks; only the menu-bar
diagnostic has LSUIElement=true. Logs are temporary development evidence:
`/private/tmp/voicerelay-window-repro-build.log` and
`/private/tmp/voicerelay-menu-repro-build.log`. No diagnostic GUI was launched or
automated. Runtime comparison remains the operator's next check.

See [the beginner-friendly diagnostic guide](../Diagnostics/StatusItemRepro/README.md)
for exact Xcode steps, a results table, and stack capture if needed. Recreating
the production project is not justified by current evidence. A warning reproduced
in the minimal menu-bar app would substantially weaken the retrofit hypothesis;
a clean control with warnings only in VoiceRelay would justify further comparison.

## Migration and Xcode checks

The new project has app, CLI, and core-test targets, a shared `VoiceRelay` scheme,
and a local Swift package dependency on the unchanged native core. The package
and Xcode workspace retain identical dependency locks.

| Migration check | Result and scope |
| --- | --- |
| Selective transfer | 29 runtime/test/build files match the earlier native source byte for byte: Sources, Tests, Packaging, Acknowledgements, manifest, pins, sample TOML, build script. Docs were updated separately. No live config, Python source, old build output, or Git metadata was migrated. |
| Reference preservation | All 69 original reference/config/state/artifact/media files, all 33 migration-source files, and the 47-file earlier native installed snapshot match their private SHA-256 baselines. No original file was deleted. |
| Project structure | `plutil -lint VoiceRelay.xcodeproj/project.pbxproj Packaging/Info.plist` passed. Parsed target/source/product references, scheme/workspace XML, and matching package locks passed focused structural checks. This is not a compilation result. |
| Script syntax | `bash -n scripts/build-app.sh` passed. |
| Native recovery-driver compilation | `swiftc -I Sources/CSQLite -module-cache-path /private/tmp/voicerelay-migration-modules scripts/check-process-recovery.swift -o /private/tmp/voicerelay-check-process-recovery` passed with no diagnostics. Direct compilation used permitted temporary output/cache paths. |
| Native recovery-driver execution | All five SIGKILL/restart/idempotence cases passed against the previously built Debug CLI in `/private/tmp/voicerelay-native/.build/out/Products/Debug/voicerelay`. Fresh owned temporary workspaces, one stable episode, preserved reserved dates, zero unnecessary synthesis after encode, and unchanged repeat audio/feed bytes. The CLI was built before relocation from the byte-identical source; this does not validate the new Xcode build. |
| Relocated SwiftPM suite | Blocked before source compilation by the manifest sandbox restriction below. No new test pass is claimed. |
| Xcode Debug build-for-testing | Blocked during manifest resolution by the cache write restriction below. App/CLI/test compilation, resource embedding, signing, and GUI launch remain operator gates. Release was not attempted after the same resolution prerequisite failed. |

SwiftPM's fresh `swift test` attempt used cache/config/security/module paths in
`/private/tmp` but stopped before source compilation with
`sandbox-exec: sandbox_apply: Operation not permitted`. Xcode's Debug
`build-for-testing` attempt used temporary DerivedData, package checkouts, and
repository caches. The five pinned dependencies were checked out from existing
caches, but manifest resolution stopped when diagnostics emission attempted to
write `/path/to/home/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/voicerelay.dia`
outside the permitted workspace. These are environment/access failures; neither
attempt supplies a passing relocated build or test result. No escalation or
desktop permission request was made.

## Historical Slices 1–2 checks before relocation

| Check | Command / observation | Result and scope |
| --- | --- | --- |
| Environment | `sw_vers`, `xcodebuild -version`, `swift --version`, SDK lookup, tool version and signing identity inspection | arm64; macOS 27.2, Xcode 27.0, Swift 6.4, macOS 27 SDK, ffmpeg/ffprobe 9.0.2; no valid signing identity |
| Dependencies | `swift package resolve`; inspected pinned manifests, public APIs, and redistribution notices | SwiftReadability 0.3.3, SwiftSoup 2.13.6, TOMLDecoder 0.4.5 and resolved transitive revisions recorded; notices copied |
| Native suite and debug app/CLI build | `swift test` | 16 Swift Testing tests passed; URL and recovery tests each have five parameter cases. XCTest's separate zero-test message is not the test count. Includes actual encoder/probe/decode operations and a first-creation /private/tmp alias regression. |
| Configuration compatibility | Native `voicerelay doctor --config` and isolated `fixture --config` against the existing customized file | Parsed read-only; existing media/tool presence observed; explicitly reported Safari, speech, delivery and worker gates. Fixture produced seven chunks, then resumed with zero new synthesis. No live state opened or created. |
| Actual process termination | `python3 scripts/check-process-recovery.py <debug-cli>` | All five owned-child SIGKILL/restart/idempotence cases passed: completed chunk, encoded, audio placed, episode committed, feed replaced. Stable IDs/dates, one episode, unchanged repeat bytes, OS lock release verified. |
| Script syntax | `bash -n scripts/build-app.sh`; Python AST parse of recovery driver | Passed |
| Reference preservation | SHA-256 comparison of the private pre-implementation baseline | All 69 inspected reference/config/state/artifact/media files unchanged, including customized TOML and published data. This is local preservation evidence, not external server integrity. |

The suite covers anchored paths, tilde expansion, customized encoding settings, legacy backend
retention, safe errors, HTTPS and path/privacy rules, non-native/newer database rejection,
competing writer exclusion, semantic/narration order/Unicode/bounds, chunk provenance,
multiple lossless artifacts via another backend, repeated UUID/GUID/date/audio/feed preservation,
exception recovery at five boundaries, same-size damaged chunk recovery, damaged published
audio blocking feed replacement, missing-feed repair without TTS, and tool timeout/cancellation.

Initial failures in generic TOML container handling and filesystem URL restoration were
localized and repaired. A later callback-binding compile failure was corrected by labeling
the UI progress callback explicitly. The corrected full test run passed. These are code-fix
results; the first restricted compiler attempt also hit a sandbox/cache-access limitation,
which was resolved by building with authorized normal Xcode compiler-cache access.

A fresh fixture under `/private/tmp` exposed Foundation's differing canonical URLs for existing
versus not-yet-created paths. Path comparisons now resolve existing filesystem ancestors with
`realpath`, and symlink checks stop at the canonical workspace boundary. The new regression
creates a fixture through `/private/tmp`, resumes it through `/tmp`, and verifies unchanged
identity and zero synthesis. Internal symlink rejection remains covered by its own test.

## Historical packaging and launch checks

The initial release app/CLI builds and `scripts/build-app.sh release` passed. The resulting
arm64 app contains its SwiftPM fixture bundle and redistribution notices; `plutil -lint` and
`codesign --verify --strict --verbose=2` passed. A restricted `open` returned LaunchServices
error -10827 despite valid executable/plist/signature. Authorized normal-context `open`
succeeded and a process query confirmed the app executable running.

The final corrected `swift build -c release` passed for both app and CLI. Packaging initially
failed on a repeated build because copied dependency license files retained read-only modes.
The script now replaces those generated copies with `cp -fR`; two consecutive release app
packaging/signature-verification runs passed. The final bundle was transferred with a guarded
hash check that refused external changes, then reopened successfully in its installed path.

No GUI controls or Canvas previews were inspected. The user subsequently specified
manual GUI/Mac acceptance and no automated computer use. The earlier launch/process
smoke check is historical evidence and is not GUI acceptance or an Xcode launch check.

## Outstanding acceptance gates

- Actual Xcode Canvas rendering of the six named source-local previews; build coverage only.
- Fresh relocated SwiftPM build/test, Xcode Release/test-bundle builds, and the core
  suite under Xcode. The operator has reported a successful app build; the observed
  Xcode Debug app passed resource/signature/metadata inspection and its CLI passed
  cold/repeat fixture validation. Those checks do not establish all build/test gates.
- Settings/import, inspection, fixture pause/resume/repeat, and normal quit acceptance
  by the user. Menu-bar visibility and a panel showing fixture completion now have
  operator evidence; this does not establish all interactions. Do not request
  computer-use permissions.
- Exact diagnostic scheme/launch warning matrix and any further runtime-warning
  isolation. Operator-labeled `.window` and `.menu` excerpts both show Intents/linkd,
  layout recursion, and task-name-port diagnostics; the style change did not
  eliminate them. Exact launch/click timing, debugger/executable configuration,
  explicit diagnostic open/Quit results, and root cause remain unresolved. The new
  `.menu` diagnostic builds in Debug/Release; Canvas remains unverified.
- Representative real-source extraction completeness, consent/login/error-page handling, and
  bounded HTTP retrieval. Slice 2 intentionally loads a saved synthetic fixture.
- Real Safari hierarchy/reconciliation and privacy access, first interactively and then by the
  final scheduled executable. No real Safari entries were ingested or altered.
- Intelligible speech and listening acceptance remains open. The October 2 benchmark
  now selects Kokoro via mlx-audio; synthetic contract tests still produce tones.
- Persistent helper/agent bundle, versioned XPC, SMAppService authorization, automation baseline,
  scheduled retries, user login/restart/sleep-wake, process-group cleanup for future helpers,
  and actual-agent Full Disk Access/Keychain checks. No worker is enrolled.
- Backed-up native adoption of Python schema/data/artifacts. Python/live databases are refused.
- Physical power-loss behavior, large/long article resource limits, disk-full error injection,
  mounted-volume loss during an active write, and production-grade settings changes/regeneration.
- Actual live media-host/Tailscale checks, WebDAV secret and destination setup, deliberate
  complete-feed upload, authenticated remote XML, and Overcast discovery/download/playback.
- Native Caddy service equivalence/ownership and intentional cutover; none attempted.

No Python test suite was rerun: no Python code changed. Existing external delivery experiments
remain historical evidence. No network article, credential, feed upload, model download,
automation enrollment, live migration, or infrastructure change was part of these checks.

## Operator validation from the new root

In Xcode, open `VoiceRelay.xcodeproj`, choose **VoiceRelay → My Mac**, build with
⌘B, run with ⌘R, and run the existing core suite with ⌘U. The app uses a waveform
menu bar item and has no Dock icon. Quit another VoiceRelay copy first. Inspect the
six previews in `Sources/VoiceRelayApp/VoiceRelayApp.swift` with Canvas enabled.

For repeatable command-line evidence in your normal Terminal:

```sh
cd /path/to/VoiceRelay
swift test
swift build -c release
./scripts/build-app.sh release
native_bin="$(swift build --show-bin-path)"
swift -I Sources/CSQLite scripts/check-process-recovery.swift "$native_bin/voicerelay"

xcodebuild -project VoiceRelay.xcodeproj -scheme VoiceRelay \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile build-for-testing
xcodebuild -project VoiceRelay.xcodeproj -scheme VoiceRelay \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile test-without-building
xcodebuild -project VoiceRelay.xcodeproj -scheme VoiceRelay \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile build
codesign --verify --strict "$PWD/DerivedData/Build/Products/Release/VoiceRelay.app"
plutil -lint "$PWD/DerivedData/Build/Products/Release/VoiceRelay.app/Contents/Info.plist"
```

Confirm `Contents/Resources/VoiceRelay_VoiceRelayCore.bundle` and
`Contents/Resources/Acknowledgements` exist in the Xcode app. For manual acceptance,
import the external customized profile read-only, select a dedicated empty fixture
folder, run once, inspect blocks/chunks, then run again and confirm zero new synthesis.
Exercise Pause and Quit during work and explicitly resume. Verify original TOML/live
data are unchanged. This validates mock mechanics; listening/speech, Safari, service,
Keychain, migration, and delivery remain the separate later gates above.
