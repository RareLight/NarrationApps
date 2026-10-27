# VoiceRelay architecture

Current application contract reviewed October 21, 2026. Shared processing lives
in the monorepo's [SwiftNarration packages](../../docs/ARCHITECTURE.md).
VoiceRelay owns Safari discovery, source authorization, retained identity/text,
SQLite queue/recovery, Publishing/Keychain, backup and GUI lifecycle.

## Components

| Component | Responsibility |
| --- | --- |
| VoiceRelayApp, AppModel, SettingsViews, MenuBarViews, WindowPresence | Native scenes, preferences, actions and cached UI projections |
| AppModelSync, AppModelSpeechSetup, AppModelHealth, AppModelEvents | Main-actor extensions for existing owned Sync, setup, cached health and ordered event projection; AppModel retains stored state/lifecycle |
| ReadingList, SourceReview, Extraction, ArchivedArticles | Read-only Safari inventory, authorized fetch/archive lookup and app-specific source policy |
| PDFArticleExtractor, ImageNarration | Thin adapters to shared native document/image processing |
| Store, SpeechQueue, FixtureCoordinator | Durable snapshots, admission, job identity, checkpoints and queue ownership |
| SingleWorkerSpeechPipeline, NativeMLXBackend | App/backend adapter, helper reuse, fixed prepared chunks and CPU finalization |
| Audio, Feed, Delivery, DeliveryRead, ServerRecovery | Native AAC, local publication, WebDAV proofs, feed confirmation and reconciliation |
| Uploads, AudioRetention, LibraryBackup | Durable outbox, safe local cleanup and review-gated backup/restore |
| NativeSpeechSetup | Explicit shared model preparation and offline setup checks |

The GUI links shared contracts/assets, not MLX. Xcode embeds VoiceRelaySpeechWorker,
Metal and notices. The UI presents Kokoro's supported English voice subset; Soprano
exists in the shared engine but is not a VoiceRelay voice selector. No product CLI,
Python helper, external codec executable or persistent agent is maintained.
An optional `SMAppService.mainApp` login item launches the ordinary app after sign-in;
initial setup and General Settings offer the same off-by-default control. Read OS
status on launch/Settings activation, reflect pending or revoked consent, and never
register automatically. Login launches suppress default/restored windows using the
open-application event's login-item marker; ordinary manual launches keep their
existing window behavior. Quit joins registration work and stops app-owned work;
the login item does not restart the app until the next login. Injected/inert models
use fake services or none. See [native provider](KOKORO_PROVIDER.md).

The menu-bar host owns one native `NSStatusItem` and transient `NSPopover`.
Both mouse-button releases use the same target/action, presenting the existing
SwiftUI `RelayMenu`. The application supplies its window/Settings scene actions
explicitly to the hosted content; menu navigation dismisses the popover first.
An intrinsic-width SwiftUI Layout measures command rows first, expands the total
horizontal width by 25%, then fits status, progress and separators into that width.
Copy Podcast URL reuses the configured public-feed clipboard action without
starting synchronization. The status-item slot uses the standard square length.
The symbol uses an explicit point-size configuration at twice the system font
size, rather than enlarging only the image canvas; native image fitting keeps it
within the button's bounds.
Text sizing remains inherited, and
Tab enables focus effects without consuming the key's normal navigation.
Creation is deferred outside scene updates, inert models never install an item,
closing the last ordinary window keeps the app alive, and Quit removes the item
after joining owned work. No private presentation API or
global mouse monitor is used.

## Sources, admission and identity

General owns Safari source selection and automation preferences. Production defaults
to `~/Library/Safari/Bookmarks.plist` only when no source was selected. Injected/inert
models never default to protected Safari data. The app refreshes at launch, every
five minutes, on Articles appearance/source changes and through pull-down refresh.
Safari entries/flags are strictly read-only. Failed reads retain known state.

All Articles joins live source inventory and retained jobs, ordered by original
saved date with stable ties/undated last. Queue keeps processing order. Each scope
has independent selection/search/filter state; selection mutations target visible
rows, while processing drains all eligible work independently of filters.
Manual admission captures the selected voice/speed and prepares in displayed order.
Duplicate/preparing entries are excluded appropriately; failed automatic admission
waits until a new session rather than looping. Article Preview owns its own cancellable
fetch and does not silently enqueue work. Snapshots retain verified source/semantic
bytes and provenance; offline resume reuses them. See [source handling](SOURCE_REVIEW.md).

A successful refresh that finds a removed Safari entry excludes it from Articles/
Queue, cancels matching admissions and joins matching speech before owned cache/
checkpoint cleanup. Failed refreshes preserve data. Published Server Audio history
and server bytes survive source removal. Queue-only removal leaves source/saved
text/server media intact. Explicit local discard also persists cancellation intent
so interrupted work cannot recreate a deliberately discarded copy.

## Speech, finalization and lifecycle

A per-library lease owns processing; short metadata transactions remain available.
NativeMLXBackend adapts the shared NativeSpeechSession to PreparedTTSBackend.
Captured dictionary rules and semantic projection are prepared before freezing
acoustic totals. Final chunks carry prepared phonemes/source mappings and synthesize
once, without another app-specific chunker or G2P pass. Helper reuse spans compatible
articles; pronunciation/model/policy identity rejects incompatible unfinished reuse.

One speech worker can overlap one FIFO CPU finalizer and bounded validation work.
The common inference lease gives Libro interactive priority and VoiceRelay background
admission at safe boundaries. Cached workers may remain resident while waiting;
no second inference worker or automatic fallback replay is launched.

Generate Audio drains Ready work, pending admissions and late additions. A row
failure remains actionable while unrelated Ready rows continue; database-wide or
unsafe shared-state failures can stop the drain. Stop abandons only interrupted
speech scratch, returns that row to Ready and suspends automatic processing until
new work/Generate; already-started finalization may finish. Quit cancels and joins
owned work while retaining recovery checkpoints. Window closure does not stop work.
Enabled automation resumes eligible work after relaunch; failed speech remains
manual Retry. Sync Now coalesces repeated requests, checks/discovers/adopts eligible
work regardless of automatic admission/processing preferences, and does not change
them. Restore review overrides all production mutation/sync paths.

Audio is mono AAC-LC/M4A at 64 kbps/24 kHz through shared native processing, without
normalization, leveling, gain, limiter or DRC. VoiceRelay's saved artifact gap becomes
a structural minimum rather than a second inserted blanket gap; explicit zero
remains zero. Semantic/acoustic and encoding identities are independent. Incomplete
incompatible plans reprepare safely; published or verified already-placed final
media is preserved even if older scratch has disappeared.

## Publishing, recovery and cleanup

New admissions capture General's default-on timed-transcript choice in the episode
profile. Missing choices on historical profiles remain disabled. NativeAudio's
encoder returns each input's actual output PCM frame interval after resampling and
gap insertion; sample processing and encoding policy are unchanged. VoiceRelay
groups those intervals by immutable prepared request, including multi-artifact
requests, and produces escaped plain-text WebVTT cues at segment granularity.
No inferred word timing or speech recognition is performed.

`EpisodeTranscript` retains bounded UTF-8 WebVTT, language, audio SHA-256 and content
SHA-256 in the episode record. Its independent DeliveryState survives cleanup,
encoding recovery and metadata-only backup/restore. Transcript failures never
block unrelated media or feed entries. Authenticated bounded GET/readback confirms
exact bytes before the episode gains a standard Podcasting 2.0 reference. Uploads
surface transcript retry/pending publication separately from audio completion.
An immutable `<episode-id>-<transcript-hash>.vtt` object shares the existing audio
collection. Existing different contents are never overwritten. Backoff, explicit
retry, destination identity and cancellation-before/after-PUT remain durable.

Namespace-aware feed recovery preserves validated transcript references without
fetching arbitrary linked text. Audio replacement invalidates incompatible local
transcript text/references; reidentification resets old-path upload proof. Only
app-owned filename patterns under the current public audio base authorize sidecar
retirement, after confirmed feed removal. External transcript references never
authorize deletion. Old-destination copies remain untouched. See the
[WebVTT specification](https://www.w3.org/TR/webvtt1/) and
[Podcast Namespace transcript tag](https://podcasting2.org/docs/podcast-namespace/tags/transcript).

The main app bundles `icon/VoiceRelay_Cover.jpg` as its initial podcast artwork.
After loading preferences, production launch prepares it through the existing
bounded artwork converter/store off the main actor, only for an unset cover choice.
Initial publishing waits for that owned import. Explicit custom selection or
removal wins, including during preparation; Quit cancels/joins the import. Injected
models import only on explicit fixture request into a supplied temporary store.
The bundle checker verifies exact source/resource bytes in Debug and Release.
The compressed 1700×1700 RGB JPEG replaces the original PNG as the bundled input.
Existing saved covers and explicit removal stay selected. Re-select the new JPEG
in Publishing to replace a previously saved default. Both input formats already
pass through the same bounded JPEG converter before publication.

Publishing owns HTTPS Feed/Public folder URLs, channel preferences and credentials;
passwords are device-local data-protection Keychain items, accessible after the first
unlock following a reboot, including while locked. No biometric/passcode/companion
flags are required. Background reads disallow authentication UI; older protected
items report a sanitized instruction to re-save in Publishing. Explicit Save updates
the password and access control together in place (also for unchanged bytes), with
interactive authorization permitted only for explicit mutations. Failed/cancelled
updates preserve the old item and cached value. Service/account identity is unchanged;
no legacy/plaintext fallback is used. Test Connection reads folders and does
not establish write permission or public mapping. Rendering/opening Settings must
not access Keychain, contact servers or write metadata. Credential session reuse
ends at Quit; denied access must not trigger automatic repeated prompts.

The durable outbox distinguishes transfer, verification, pending feed publication,
local cleanup conflicts and published history. Bytes-sent progress is not integrity
or publication proof. Confirm current-destination media and authenticated feed
contents before membership confirmation/local cleanup or remote deletion. Preserve
backoff, proof expiry, conditional requests and per-item failure isolation.
Destination changes invalidate old proofs/delete intentions and preserve old-host
copies. Server retirement removes feed membership before media deletion and retains
unfinished removal state until confirmed.

Automatic reconciliation uses exact episode/retained-link evidence, not titles or
orphan filenames. Matching verified server media can restore history without speech
or media PUT. Longer valid copies win under comparable settings; ties favor server
copies and replacements preserve prior media. Unsafe feed-wide state blocks mutation;
per-item errors preserve membership and let unrelated work proceed. See
[server reconciliation](SERVER_RECOVERY.md) for limits and conflict rules.

App-owned temporary audio is released only after verified publication and committed,
identity/hash-checked cleanup. Explicit local discard is distinct from server
retirement; deliberately discarded copies are not automatic replacement winners.
Durable outbox/history/proofs survive transient UI filters and relaunch.

## Persistence, presentation and validation

The native library stays at
`~/Library/Application Support/VoiceRelayPrototype/SpeechLibrary`; the compatibility
path is intentional. Models use the sibling managed SpeechRuntime directory.
Preferences are app-owned UserDefaults; credentials remain Keychain-owned. SQLite
WAL and short transactions preserve identities, saved dates and known fields in
stale worker saves. Backups include retained text/bookkeeping, not audio, models,
preferences or passwords. Restore stages/validates before swapping, retains the
previous library and blocks automation/delivery/cleanup until Finish Library Review.

AppModel uses main-actor cached projections; disk parsing, ledger/preflight,
audio, process and transport work belong off the UI actor. Owned tasks have stored
handles, cancellation and join paths; revision guards reject late results after
removal, destination edits or restore. Common Settings/typography live in
AppPresentation and NarrationUI; the app owns General, Pronunciation, Publishing
and Troubleshooting, window/Dock presence and Help topics. Help is inert/offline.

Use [CONTRIBUTING.md](../CONTRIBUTING.md) for safe checks,
[VALIDATION.md](VALIDATION.md) for current evidence and the
[single operator checklist](../../docs/OPERATOR_VALIDATION.md#voicerelay)
for GUI, live services, listening and restoration. Those are not established by
compile/fixture success. Older stage results remain in Git history.
