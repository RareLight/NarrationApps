# VoiceRelay

VoiceRelay turns Safari Reading List articles into a private podcast using local
Kokoro speech and WebDAV publishing. While the macOS app runs, it discovers
articles, prepares saved text, processes the queue and publishes episodes according
to your preferences. Failed items remain available for manual Retry. Safari
bookmarks and Reading List flags are never modified.

Requires Apple Silicon, macOS 27.0+, Xcode with the macOS 27 SDK (Swift 6.2+),
python3, uv, ffmpeg and ffprobe. Speech uses a pinned, explicitly installed runtime.
Audio is mono 24 kHz AAC-LC/M4A at 96 kbps, with original levels and dynamics: no
normalization, gain, limiter or dynamic range compression. Narration opens with
article title/source and ends with “End of article.” Episode dates use Reading List
save dates when available; optional publisher artwork stays external.

## Build and setup

Copy `Packaging/Signing.example.xcconfig` to the ignored `Signing.local.xcconfig`
at the project root and set your team there, or select your team in Xcode's
Signing & Capabilities. Debug and Release load the local file automatically. Use
an Apple Development identity and a matching provisioning profile for the Data
Protection Keychain entitlement. Open `VoiceRelay.xcodeproj`, choose **VoiceRelay →
My Mac**, build and run. To package a signed Release build without launching it:

```sh
bash scripts/build-app.sh release
```

The script copies Xcode's signed bundle to `dist/VoiceRelay.app` and verifies it.
Private signing files, generated output, runtime/model assets and backups are
ignored. Neither building nor starting the app downloads models.

In **Settings → General → Speech setup**, choose **Install Speech Runtime…**.
Installation explicitly downloads pinned Python, packages and model/voice assets;
**Check Speech Runtime** verifies them offline. The managed runtime is under
`~/Library/Application Support/VoiceRelayPrototype/SpeechRuntime`. Existing
checkout installations remain supported. Cancel and Quit join owned setup work;
global environments are unchanged. See [Kokoro setup and pipeline](docs/KOKORO_PROVIDER.md).
The result appears beside Check: Not tested, Runtime verified or the failure.
Publishing and source refreshes do not disable speech setup controls; active audio
work and library maintenance do, with a reason shown in General.

## Everyday use

The waveform menu opens a compact popover with overall status, **Sync Now**,
**Articles**, **Server Audio**, **Settings** and **Quit VoiceRelay**. Green **Ready**
requires a successful Reading List read, verified speech runtime and verified
WebDAV connection this session. A red problem status opens its affected Settings
pane. Startup checks the installed speech runtime offline, without downloading.

**Sync Now** refreshes the Reading List, checks existing server audio, prepares new
articles, generates Ready work and publishes it, even when automatic admission and
processing are off. It does not change those preferences or retry failed speech
rows. During this one-shot task, its button becomes a compact phase progress bar:
measured generation/current-file transfer progress, animated checks, then the button returns.
Articles and Queue are scopes in one library window alongside Uploads and Server
Audio. Opening a standalone window enables the Dock/⌘-Tab entry; closing the last
returns to menu-bar-only operation. Closing windows does not stop work.

1. In **General → Speech**, choose Language & Region, Voice and speed. Defaults
   are US English, Heart and 1.0×. Voice choices are ranked by upstream quality
   grades: ten US voices and eight UK voices. New admissions capture these choices.
2. Safari's `~/Library/Safari/Bookmarks.plist` is the default source. In
   **General → Reading List**, choose another file if needed. Discovery runs at startup,
   every five minutes, when Articles appears or the source changes, and on
   Articles' pull-down gesture. Newest saved items appear first; ties keep discovery
   order and undated entries come last. Automatic admission and processing are
   controlled by the General preferences.

3. **Add to Queue** prepares selected articles in displayed order in the
   background, showing Preparing and per-entry failures. Saved text is reused
   offline. Double-click or **Preview Article** opens the dedicated preview window;
   that window fetches the page. Optional **Try archived copies when articles
   fail** is off by default; see [article handling](docs/SOURCE_REVIEW.md).
4. **Generate Audio** (⌘⇧G) drains Ready work, pending preparations and late
   additions in processing order. **Stop** (⌘.) returns interrupted speech to
   Ready and suspends automatic processing until new work arrives or Generate is
   pressed; already-started finalization can finish. Quit joins owned work while
   retaining recoverable checkpoints. Relaunch resumes eligible automation.
   Failed rows require Retry; they are not repeatedly retried automatically.
5. Queue removal deletes only queue membership. Source entries, saved text and
   server audio remain. Individual and multi-selection removal need no
   confirmation; **Reset Queue…** does. Scope selections remain independent.

Search in Articles (All Articles/Queue), Uploads and Server Audio matches visible
titles, source, saved dates, status and errors. Searches are local, combine with
the Website/state filters and do not restrict automatic processing or publishing.

Articles, Queue/preparing rows and Server Audio share the original-website and
Saved-date line. A missing saved date is omitted rather than replaced by the
voice-generation date. Progress appears only during owned work; publishing is
shown separately from speech/finalization.

## Publishing and Server Audio

In **Settings → Publishing**, supply complete HTTPS **Feed folder URL** and
**Public folder URL**, channel details and WebDAV credentials. For example,
`https://webdav.example/podcast/` can upload files served at
`https://podcast.example/`. Follow your provider's mapping instructions; these
addresses need not be identical. VoiceRelay puts `feed.xml` and lowercase `audio/`
under each folder. **Subscription URL** is read-only with **Copy** for Overcast
or another podcatcher.

Pasted URLs normalize on commit: whitespace, missing HTTPS, spaces/percent escapes,
redundant slashes, dot segments, default ports and trailing slashes are handled.
A pasted feed.xml URL resolves to its parent. Credentials or query parameters
require a field-specific correction and are never echoed in diagnostics.

Passwords persist only in the device-local Data Protection Keychain. macOS chooses
available authentication methods, which can include Touch ID, supported Apple
Watch authorization or your Mac password. Successful access is reused until Quit;
opening Settings does not query Keychain. Cancelling does not cause automatic
reprompting. Saving/removing credentials may require separate system confirmation.

**Test Connection** probes folders read-only; it proves neither write permission
nor the public website mapping. A readable ancestor permits a missing-folder
result; uploading creates folders if authorized. **Upload Now** is the manual retry
override. Enabled publishing also drains after publication/removal, launch and
periodically while the app runs. Media size is confirmed with HEAD or WebDAV
metadata before feed publication.

**Server Audio** is durable episode history. **Published** means current-destination
media bytes and feed membership are confirmed. **Upload New Items** appears only
while shown episodes need upload/publication. Removing an episode retires feed
membership before remote media deletion, and keeps unfinished removals visible.
**Reset Server Audio…** requires confirmation. Source entries and retained text
are preserved. **Show in Finder** applies only to older remaining local copies.

Server Audio sorts newest article saved dates first, with undated episodes last.
Saved dates and original websites remain searchable after removing the source
article from Safari; generation dates do not replace missing saved dates.

Finished audio uses app-owned macOS temporary storage. Its local copy is removed
only after both media and feed confirmation, with committed cleanup intent and
hash/file-identity checks. Missing unconfirmed output regenerates from retained
text under the same GUID and captured voice; failed rows stay manual Retry.
Destination changes recreate released bytes and preserve old-host files. There is
no audio-folder preference or scheduled retention policy.

Remove unwanted articles in Safari Reading List. After a successful source refresh,
VoiceRelay removes them from Articles and Queue and clears cached article text and
unfinished generation files. Server Audio history and server copies remain until
you remove them in Server Audio. Unconfirmed finished local audio stays available
for publishing; confirmed media/feed copies can be released locally as usual.
Failed source reads preserve the library. Private backups already exported are
not changed by later article removal.

The Articles filter starts with **Today** and **This Week**, based on the Reading
List saved date in your local calendar. Undated articles appear under All Websites
or their website filter. Search combines with the selected filter in each scope.

Publishing automatically reconciles existing server feed/audio with local state.
Verified matches restore history and leave Queue without regeneration or media PUT.
At comparable voice/speed, the longer valid copy wins; ties retain the server copy.
Replacements preserve the old server file, and item errors retain its feed membership
while unrelated work continues. Cached proofs and conditional requests reduce
repeated downloads. Exact identity or retained-link evidence is required; titles
and orphan filenames are insufficient. See [automatic reconciliation and operator
tests](docs/SERVER_RECOVERY.md) for conflict rules, caching and matching limits.

## Private state and backups

The native library remains at
`~/Library/Application Support/VoiceRelayPrototype/SpeechLibrary`. Compatibility
paths and internal preference keys are retained. Clearing Xcode Derived Data does
not erase the library; changing the app bundle identifier changes its preferences
domain. The app owns processing/publishing; no agent or service enrollment exists.
The original Python reference, customized state and published files are preserved
in their existing locations and never silently imported.

**Troubleshooting → Library backup** exports retained text, inventory, queue,
episode history and delivery bookkeeping using SQLite backup, including WAL
commits. Backups exclude credentials, preferences, audio, scratch and models.
They contain private source content and server information: keep them private.
Restore validates/stages before replacing the library, preserves the previous
library and disables automation/publishing behind **Finish Library Review**.
It does not change Safari, local audio or server files. See [backup/restore checks](docs/BETA_TESTING.md#4-private-library-backup-and-restore).

**Troubleshooting → Enable debug logging** retains the newest 200 events in memory.
The toggle persists; events do not survive Quit. Copy Debug Log and Clear Log
operate on this session. Logs include sanitized HTTP outcomes/stage timings,
never credentials, URLs, paths, source text, authorization headers or server bodies.

## Development and validation

The Swift package shares the native core across the app, diagnostic CLI and tests.
Use isolated fixtures; never point tests at live library or Safari input.

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --cache-path "$PWD/.build/swiftpm-cache" --disable-sandbox --skip-update
python3 -m unittest discover -s runtime/kokoro/tests
```

After changing project.pbxproj, run the
`xcodeProjectAppSourcesUseUniqueBuildFileReferences` regression. The CLI's
`--help` lists explicit diagnostic commands; it never uploads or enables automation.
A safe source-discovery fixture is:

```sh
swift build --product voicerelay
native_bin="$(swift build --show-bin-path)"
"$native_bin/voicerelay" reading-list --plist "$PWD/Fixtures/reading-list.synthetic.plist"
```

Build/fixture results do not establish GUI, Canvas, protected-file access, actual
speech/listening, Keychain or live DAV/Overcast acceptance. Those checks are manual.

| Guide | Purpose |
| --- | --- |
| [Architecture](docs/ARCHITECTURE.md) | Current components, storage and safety boundaries |
| [Development handoff](docs/DEVELOPMENT_HANDOFF.md) | Working context and code map |
| [Roadmap](docs/IMPLEMENTATION_PLAN.md) | Remaining beta gates and later priorities |
| [Beta checks](docs/BETA_TESTING.md) | Operator speech, setup, interruption and backup tests |
| [Native UI acceptance](docs/UI_ACCEPTANCE.md) | Layout, keyboard and accessibility checks |
| [Validation evidence](docs/VALIDATION.md) | Dated results and unverified acceptance |
| [Approved design](docs/design/README.md) | Synthetic design record, distinct from native UI |

## License

VoiceRelay is licensed under the [GNU Affero General Public License v3](LICENSE).
Dependencies and runtime/model assets retain their own licenses; see
[Acknowledgements](Acknowledgements/README.md). Downloaded assets are not
included in Git. Fully bundled tools, notarization and distribution remain future
release decisions.

**Uploads** is the publishing outbox, between Articles and Server Audio. It shows
per-item transfer progress, pending feed publication and verification failures.
Confirmed published items leave the outbox; unresolved local cleanup conflicts
remain with their diagnostics. Both screens have independent **Filter** menus,
including **Needs Attention** and **Failed Verification**. Filter changes do not
contact the server. Partially generated speech remains in Articles → Queue.

Uploads rows offer **×** to discard only their tracked local copy, keeping server
audio and saved article text. Explicitly discarded copies are not automatically
regenerated. Failed removals remain listed for retry. Server Audio records an
unpublished discarded copy as **Local Upload Removed**.

Articles and Queue each retain their own **Website** filter. Foundation parses
and normalizes original hosts; HTTP/HTTPS, capitalization, trailing host dots
and `www.` aliases group together. Other subdomains stay distinct. Filtering does
not change source URLs, processing order or automatic processing; selection
actions apply only to visible rows.

Explicit local discard also cancels matching native queue membership atomically
with its intent, preventing an interrupted Ready job from recreating the file.
Reading List entries and retained snapshots remain available for manual re-enqueue.
Discarded local copies never become automatic reconciliation replacement winners.

For publishing or backup guidance, open **Help → Publishing and Uploads** or
**Help → Library Backup and Restore**. Section ⓘ controls give brief summaries;
**More Help…** opens the corresponding guide. Help content is bundled and offline.
