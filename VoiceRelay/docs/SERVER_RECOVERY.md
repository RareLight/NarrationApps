# Automatic server reconciliation

VoiceRelay reconciles the authenticated server feed with its local library before
starting queued generation and through the ordinary publishing drain. There is no
separate Check Server Audio control or recovery approval step. Library restore's
Finish Library Review gate still blocks all automatic processing and server changes.
Test Connection remains a read-only folder probe, not a synchronization action.
Every configured/enabled app launch attempts reconciliation, including relaunches
within the five-minute cadence. This bypasses only the scan's cadence gate: valid
audio proofs, conditional feed requests and upload retry delays remain effective.
Cancelled/unavailable Keychain access is remembered for the session; only explicit
retry can prompt again. Startup shows Checking Publishing; failures offer Review
Publishing directly, independently of Uploads warnings.

## Identity and conflict policy

New feeds record SHA-256 hashes, original article identities, voice and speed.
Older feeds match exact article links or unambiguous links from retained,
integrity-checked snapshots. Titles and opaque filenames are never matching proof.
Valid episodes with no exact original match can be retained as server-only history.
No directory-wide orphan scan is performed; unidentified files are left untouched.

A first verification streams bounded audio to owned temporary scratch, checks its
hash and size, probes the AAC-LC/M4A format and duration, and decodes the complete
file. Scratch is removed after inspection. Hash equality establishes identical
bytes; it cannot establish that narration covers every paragraph. A successfully
finalized local artifact with an unchanged hash can reuse its recorded validation.

For differing valid copies at comparable voice and speed, a longer duration wins
when the difference exceeds 0.5 seconds or 0.1 percent of the server duration.
Equal-duration copies and known voice/speed variants retain the server copy to
avoid repeatedly replacing valid recordings. Legacy feeds lacking voice/speed
cannot establish those settings; duration is a best-effort completeness heuristic.
Damaged local bytes do not displace a verified server copy. A verified local copy
can replace an undecodable server artifact. Transport or permission failures are
not evidence of damaged audio and never authorize replacement.

A winning local copy that shares the server GUID gets a new opaque file identity:
its complete bytes are uploaded and verified before feed membership switches.
The losing server file is preserved, not deleted. A winning server copy restores
history and removes matched queue work without TTS or media PUT. Known uploads
interrupted before feed publication are reused when verified, then added to the
feed. Explicit local retirement always takes precedence over rediscovery.

## Failure isolation and efficiency

Each uncertain article gets a sanitized diagnostic and stays available for Retry;
its existing feed entry is preserved while unrelated checks and uploads continue.
An unreadable or malformed whole feed blocks feed replacement and remote deletes,
while unrelated complete local media can still upload under fresh identities.
Retries must not erase unknown feed membership. Diagnostics never include private
URLs, source text or credentials.

The idle check interval and failure backoff are five minutes. Changed queue
membership or destination triggers an earlier check. Sync Now explicitly rechecks
the server while preserving upload backoff; Upload New Items can force a retry
through the same publishing path. Metadata rekeying defers while
an inference drain owns the library. Inert previews and restored-library review
never contact the server.

Unchanged per-item hash/size evidence permits reuse of verified media proofs for
up to 24 hours, even when unrelated RSS metadata changes. Legacy entries without
hash metadata can reuse proofs while the feed is unchanged. Forced retries bypass
this fresh-proof shortcut and check current media validators/bytes. After expiry, an unchanged strong ETag and size can reuse the verified hash; otherwise
the media is read and decoded again. Servers without useful validators incur a
bounded daily media verification. Conditional feed reads avoid repeated RSS body
transfer where ETags are supported. Newly uploaded media requires SHA-256 confirmation:
a valid server Repr-Digest avoids a second download; otherwise a streamed GET checks
its hash. Feed updates use If-Match with strong ETags, or reread the feed before
writing if validators are unavailable. Fresh media uses If-None-Match: * to prevent
overwriting an unseen file. Servers without strong feed validators cannot provide
a fully atomic compare-and-swap; a concurrent external editor still has a narrow race.

See the HTTP [conditional request specification](https://www.rfc-editor.org/rfc/rfc9110.html)
and [representation digest specification](https://www.rfc-editor.org/rfc/rfc9530.html).
Public-folder mapping and actual podcatcher playback still require operator testing.

## Operator acceptance

1. Build/run the VoiceRelay scheme with normal signing. Confirm Publishing's
   existing Feed folder, Public folder and password; enable debug logging in
   Troubleshooting. No Derived Data cleanup or live library reset is needed.
2. Let the normal publishing drain run. Existing matching episodes should appear
   in Server Audio and leave Queue without speech generation or a media PUT.
   A metadata/membership repair may PUT feed.xml. Refresh the subscription in
   Overcast and verify playback, article origin and saved dates.
3. Generate one new article. It should upload once, publish, and release its local
   temporary copy only after media and current feed confirmation.
4. Confirm a quiet repeated drain reports unchanged reconciliation without
   repeated media transfers. For a deliberately unavailable disposable item,
   confirm its error is visible while unrelated work still finishes. Use isolated
   fixtures for destructive/conflicting-copy scenarios, not your production share.
5. Server removal must still retire feed membership before deleting its file and
   keep unfinished removal visible. Restore review must still prevent sync until
   Finish Library Review. Share only sanitized logs and observed status.

## Derived Data and preferences

The library remains at
`~/Library/Application Support/VoiceRelayPrototype/SpeechLibrary`, outside Derived
Data. That compatibility name is intentional. Publishing preferences live in the
application bundle identifier's UserDefaults domain. The current project uses
`org.voicerelay.tts`; earlier builds used `org.voicerelay.prototype`. Changing that
identifier can make preferences appear reset; no live preferences migration runs.
A private library backup retains snapshots and full local bookkeeping; server
reconciliation cannot recover source text that was never retained locally.

## Monitoring pending and conflicting copies

Uploads is the publishing outbox. Needs Attention and Failed Verification filters
expose per-item failures, including local cleanup conflicts after a server copy was
confirmed. The same filters are available in Server Audio history. A local cleanup
identity/hash/size refusal is not evidence of a network failure or partial TTS: the
file is retained and other items continue. Retry Uploads reuses existing proofs and
checks pending work through ordinary delivery. Rows leave the outbox after confirmed
media/feed publication and resolution of any local cleanup issue. Filters themselves
do not request server checks or download audio.
