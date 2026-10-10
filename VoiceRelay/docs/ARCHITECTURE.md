# VoiceRelay architecture

Updated October 10, 2026. This describes the current Swift/macOS application.
[AGENTS.md](../AGENTS.md) defines development constraints;
[the roadmap](IMPLEMENTATION_PLAN.md) defines remaining work. The earlier prototype
brief and checkout-migration guide are retired.

## Components and ownership

| Component | Responsibility |
| --- | --- |
| VoiceRelayApp / SourceReviewView | App-owned lifecycle, preferences, native library/Settings/preview UI |
| ReadingList | Read-only Safari plist parsing, durable inventory and saved-date ordering |
| SourceReview / Extraction / ArchivedArticles | Bounded fetching, semantic extraction, quality checks and optional archive lookup |
| SpeechQueue / FixtureCoordinator / Store | Admission, source identity, retained snapshots, queue and SQLite checkpoints |
| SpeechPipeline / ExecutableSpeechBackend / KokoroMLXBackend | Replaceable engine contract, supervised helper and single-worker processing |
| Audio / FloatWave / Feed | Audio validation/encoding, local publication and remote RSS |
| Delivery / DeliveryRead / ServerRecovery | WebDAV confirmations, feed-first retirement and explicit server reconciliation |
| Uploads | Local-copy removal, outbox projection and transient per-item transfer/verification progress |
| AudioRetention | Confirmed-upload local cleanup and missing-output recovery; no age-based retention |
| LibraryBackup / SpeechRuntimeSetup | Private SQLite backup/restore and explicit runtime installation |
| runtime/kokoro | Pinned Python setup and inference adapter, not application orchestration |

The app, diagnostic CLI and package tests share VoiceRelayCore. Package resources
contain immutable setup sources/pins; downloaded assets remain external. Xcode
builds the native app with its signing/Keychain entitlements. There is no persistent
agent, XPC ownership transfer, LaunchAgent or service enrollment. The earlier Python
application is a separate reference and is never a live state dependency.

## Discovery and admission

While running, the app checks the selected Reading List at startup, every five
minutes, on Articles appearance/source change and through pull-down refresh.
Unreadable/transient source reads retain known inventory. Safari entries and flags
are strictly read-only. All Articles combines source inventory with retained queue
jobs, ordered by saved date; Queue preserves processing order. Selections are
independent across scopes. Manual Add captures current voice/speed preferences and
prepares entries in displayed order without reordering existing queue work.

Automatic admission respects recorded audio, retained snapshots and source
membership. A failed automatic admission waits until the next session; failed
speech rows remain manual Retry. New work resumes processing suspended by Stop.
Queue removal affects only membership, never source entries or saved text.

Original URLs identify articles independently from canonical/redirected URLs.
Snapshots preserve source, semantic blocks, narration and private provenance with
integrity checks. Narration adds title/publisher, omits decorative separators and
ends with a separate End of article paragraph. Recognized footnotes are spoken
once at their first reference; unresolved notes produce a notice rather than
invented content. See [article handling](SOURCE_REVIEW.md).

Archive lookup is optional/off by default and original-first. It reads existing
Archive.ph TimeMaps then Wayback Availability captures. Queries/private hosts are
filtered, requests are bounded and redirects stay on known HTTPS providers.
No capture submission, browser credentials, remote JavaScript or CAPTCHA solving.
Publisher HTTPS preview artwork remains an external URL; absence never blocks work.

## Processing and cancellation

One per-library filesystem lease permits one inference worker while short SQLite
metadata writes continue. The active drain overlaps one synthesizing article with
one FIFO CPU finalizer and at most one pending chunk validation. The prepared
helper is reused across compatible consecutive items. Pronunciation lookahead uses
one CPU thread; cached authenticated voices and bounded MLX allocator reuse avoid
repeated preparation without changing pinned model math.

Generate Audio drains eligible Ready work, pending admissions and late additions.
Each verified local publication dequeues immediately. Failures retain checkpoints
and allow later Ready rows to continue. Stop abandons only interrupted speech
scratch and returns that row to Ready, letting already-started finalization finish.
Quit cancels/joins both stages and retains recovery checkpoints. Window closure
never stops work; enabled automation resumes on relaunch.

Output is mono 24 kHz AAC-LC/M4A at 96 kbps from float intermediates, preserving
levels/dynamics. Chunk, backend and encoding fingerprints prevent incompatible
scratch reuse; valid completed speech can survive an encoding-policy change.
Published or integrity-confirmed final audio is preserved. No normalization, gain,
limiter or DRC is applied. [Kokoro details](KOKORO_PROVIDER.md) cover setup and
performance checks.

## Publishing, identity and cleanup

UserDefaults stores provider-neutral Feed/Public folder URLs and channel settings.
Foundation URLComponents normalizes committed drafts. feed.xml and audio/ are
implicit; the subscription URL is read-only. Passwords live only in Data Protection
Keychain, with successful session reuse. Settings/readiness never query credentials.
Cancellation prevents automatic reprompting; explicit retry uses a fresh context.

Delivery confirms media bytes before feed membership. A Published state requires
both for the current destination. Server removal retires membership before DELETE,
remaining visible until confirmation. Destination changes preserve old-host files
and never carry old-host deletion requests to the new host. Errors/logs are
sanitized. Test Connection is a manual read-only collection probe, not write/public
mapping acceptance.

Publishing automatically reconciles bounded authenticated feed/media before queue
generation and through the delivery drain. Hashed original-source identity or
unambiguous retained links establish matches; titles and orphan files are never
proof. SHA-256, format inspection and complete decoding verify copies. Longer
valid audio wins at comparable voice/speed; ties and known variants retain the
server copy. Local replacements use fresh opaque identities and preserve losing
server files. Matched server audio restores history and dequeues duplicate work.
Item failures preserve existing RSS entries, log sanitized notices and leave other
work running. Whole-feed failures prevent feed replacement/deletion, not unrelated
fresh media uploads. Cadence gates, cached proofs and strong validators reduce
network/CPU use. Restore review remains an overriding gate. See
[conflict and efficiency rules](SERVER_RECOVERY.md).

New final media and helper/processing scratch use app-owned macOS temporary storage.
Cleanup commits intent, checks hash/size/file identity and unlinks only after current
media/feed confirmation. Missing unconfirmed media requeues from retained text,
preserving GUID/voice; failed rows remain manual Retry. A missing released local
copy never retires its server history. There is no storage chooser or rotation
schedule. Legacy application-owned media follows the same confirmation policy;
unrelated and original Python files are untouched.

## Persistence and recovery

The compatibility library path is
`~/Library/Application Support/VoiceRelayPrototype/SpeechLibrary`; the managed
runtime is its sibling SpeechRuntime. These names remain stable for existing
installations. Derived Data contains build output, not library/preferences.
Changing bundle identity changes the UserDefaults domain.

SQLite WAL and persisted sidecars support concurrent readers/writers. Backups use
SQLite backup, never raw database copies, and include retained text/inventory and
delivery bookkeeping. They exclude credentials, preferences, audio, runtime and
scratch. Backup content remains private. Restore validates/stages before atomic
replacement, retains the prior library and disables automation/delivery behind a
persistent review gate, including local cleanup/server changes. No test restores
live state. [Beta checks](BETA_TESTING.md) cover isolated and manual restoration.

## Native presentation and validation

The menu bar and one Articles/Uploads/Server Audio sidebar window use native controls.
Settings has General, Publishing and Troubleshooting with a selected glass tile
and keyboard-only focus cue. Glass belongs in navigation/control chrome; content
uses standard system surfaces. Text is at least 12pt, help belongs behind section
info controls, and notice dismissal changes presentation only. Progress reflects
owned speech/finalization separately from publishing and clears at terminal states.
The activity footer and its divider appear only during owned work; idle completion,
configured publishing and empty-queue messages stay out of the workspace. Setup
and errors use their existing readiness/inline notices; disabled-control reasons
remain available in tooltips.
Restore review takes precedence over setup/recovery notices.

Source-local previews are synthetic and inert. Automated isolated fixtures and
builds validate mechanics; GUI/Canvas, protected Safari access, actual speech and
listening, real Keychain, installation/relocation and server/Overcast checks remain
operator acceptance. See [UI acceptance](UI_ACCEPTANCE.md) and dated
[validation evidence](VALIDATION.md).

## Upload outbox and verification diagnostics

Uploads sits between Articles and Server Audio. It projects tracked generated episodes
from durable delivery records and current-destination feed confirmations; it does not
scan scratch directories or contact the server when changing filters. Partially
synthesized articles remain in Queue. Waiting, local verification, byte transfer,
server verification, feed publication and failures are distinct states. URLSession
upload delegate byte counts are throttled; transports without byte reporting use an
indeterminate indicator. Sending every byte is not proof of publication.

A published item clears from Uploads only when its current media hash and feed
membership are confirmed, unless local cleanup verification still needs attention.
Local cleanup commits its intent before unlink, checks file identity/hash/size and
persists a sanitized per-item notice on failure. A substituted file is retained;
other cleanup continues and publishing is not falsely reported as a connection
failure. Missing tracked temporary files clear the cleanup notice without retiring
remote history. Quiet delivery retries cleanup without new network requests.

Uploads and Server Audio have independent state filters with counts. Needs Attention
includes transfer/publication errors, server verification failures and local cleanup
conflicts; Failed Verification isolates the latter two. Published and Pending Removal
are additional Server Audio filters. Removal and confirmed reset target visible rows;
Server Audio remains durable history. Restore review blocks retries and all changes.

Explicit Uploads × removal writes `localAudioDiscarded` and an unfinished-removal
notice before unlink. It never retires server feed membership or deletes retained
text. Changed bytes are removable only in this library's recorded temporary audio
folder; legacy storage still requires the original hash/size. Regular-file, volume,
symlink and inode/race checks remain mandatory. Failures persist the row for retry.
Successful removals clear the outbox and automatic recovery/transfer skip the
discarded copy, including after relaunch or destination changes. Actual manual
regeneration clears this flag when committing fresh audio.

Articles/Queue website filters are independent, in-memory presentation state.
Choices sort by current-scope article count descending, then alphabetically for
equal counts. All Websites stays first; Unknown Website uses its count, and an
empty selected website stays available with zero. Article/queue row order is unchanged.
Foundation URLComponents/URL handles host parsing and IDNA; a narrow display alias
strips `www.` and trailing dots and folds case, scheme and port differences. No
public-suffix dependency, DNS/redirect lookup or source-identity rewrite is needed.
Other subdomains remain independent. Hidden selections never enter Add/Remove
actions; filtering never changes the actual queue or automation scope.

Explicit local discard also cancels matching native queue membership atomically
with its intent, preventing an interrupted Ready job from recreating the file.
Reading List entries and retained snapshots remain available for manual re-enqueue.
Discarded local copies never become automatic reconciliation replacement winners.

## Concise help

Section ⓘ controls show a short “About…” hover label and a brief explanation on
activation; VoiceOver hints describe the action rather than reading the entire
explanation. Tooltips explain the action or its consequence without implementation
details. Preserve deletion and archive/backup privacy information.

Publishing and backup popovers link to bundled, static guides in Help → Publishing
and Uploads / Library Backup and Restore. A typed AppHelpTopic WindowGroup reuses
ordinary window registration; the Help commands apply across the app's scenes.
Help reads no library data, opens no private files and starts no server/runtime
work. Named source-local previews render the same static guides.
