# VoiceRelay architecture

Current application contract, October 15, 2026. Shared processing lives in the
independent [SwiftNarration packages](../../docs/ARCHITECTURE.md).
VoiceRelay owns Safari discovery, source authorization, retained identity/text,
SQLite queue/recovery, Publishing/Keychain, backup and GUI lifecycle.

## Components

| Component | Responsibility |
| --- | --- |
| VoiceRelayApp, AppModel, SettingsViews, MenuBarViews, WindowPresence | Native scenes, preferences, actions and cached UI projections |
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
Python helper, external codec executable, persistent agent or service enrollment
is maintained. See [native provider](KOKORO_PROVIDER.md).

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

Publishing owns HTTPS Feed/Public folder URLs, channel preferences and credentials;
passwords are device-local Keychain data. Test Connection reads folders and does
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
compile/fixture success. Older stage results are [history](ARCHITECTURE.md).
