# VoiceRelay native macOS prototype

VoiceRelay queues Safari Reading List articles and generates local Kokoro speech
with a shared Swift pipeline: semantic extraction, narration, restartable native
SQLite checkpoints, validated mono AAC-LC/M4A and atomic local RSS. Kokoro's saved
article fixture now has operator-confirmed success. **The app and CLI have no tone
mode.** Synthetic audio providers exist only inside automated tests.

The current Slice 3 continuation adds article selection and batch enqueue, a saved
speech library with offline resume, in-app voice/speed preferences, persistent
Reading List entries, and a durable manual speech queue. Normal
app use requires no TOML file or pipeline parameters. Generated audio uses app-owned macOS temporary storage until its upload and
feed publication are confirmed, then the local copy is removed. Server Audio
retains episode history and server removal controls; metadata and article text
remain private and persistent. No folder choice or scheduled rotation is required. Article inspection
and narration previews open in a dedicated Article Preview window, reached from
Articles.
The pinned inference runtime still needs explicit development setup; bundled
runtime onboarding and automated opt-in discovery/retry scheduling remain later
work.

See [implementation sequence](docs/IMPLEMENTATION_PLAN.md),
[validation and open gates](docs/VALIDATION.md),
[source review and speech checks](docs/SOURCE_REVIEW.md),
[dormant agent prototype reference](docs/AGENT_PROTOCOL.md), and
[Kokoro setup](docs/KOKORO_PROVIDER.md). This directory is the canonical native
project. Historical Python code, customized configuration and published data are
preserved in their original locations.

Single-worker processing overlaps chunk validation and article encoding with
inference, with one resident helper and at most two articles in flight. Debug
logging in Troubleshooting includes sanitized stage timings. For throughput,
Stop/Quit and listening checks, see the [pipeline guide](docs/KOKORO_PROVIDER.md#october-7-bounded-single-worker-optimization).

## Xcode and app use

Requires macOS 27.0+, Xcode with the macOS 27 SDK (Swift 6.2+), ffmpeg/ffprobe and
the explicitly installed project-local Kokoro runtime. Open `VoiceRelay.xcodeproj`,
select your own development team in Signing & Capabilities,
choose **VoiceRelay → My Mac**, build (⌘B) and run (⌘R).
For `scripts/build-app.sh`, copy `Packaging/Signing.example.xcconfig` to
`Signing.local.xcconfig` at the project root and set your own team there.
That local file is ignored; the script passes it to Xcode without putting
signing identifiers in the shared project. Use an Apple Development identity
and a matching provisioning profile for the Data Protection Keychain entitlement.

The waveform menu-bar icon
opens a native status menu; no Dock icon or startup window is expected.
Choosing **Articles**, **Queue**, **Server Audio** or **Settings…** opens and
focuses the corresponding standalone window, which enables the Dock icon and
⌘-Tab entry while any such window is open, including when minimized. The main
window's sidebar switches between **Articles**, **Queue** and **Server Audio**.
Closing the last standalone window returns to menu-bar-only operation.

1. In **Settings… → General → Speech**, choose Language & Region, then a voice and
   speed. Defaults are US English, Heart and 1.0×. The menu shows ten US or eight
   UK voices ordered by upstream quality grade; changing region picks its
   highest-rated voice. Choices save automatically. Audio defaults are mono 24 kHz AAC-LC at
   96k, original levels/dynamics without normalization or DRC, 0.15-second chunk
   gaps and 1,800-character narration chunks. Processing uses floating-point
   intermediates. Existing finalized audio is preserved; unfinished app work
   adopts the encoding policy while retaining reusable speech chunks.
2. Configure **Settings… → Delivery** with the Feed folder and Public folder URLs
   and your app password. `feed.xml` and `audio/` are implicit. Copy the subscription
   URL into Overcast. New audio is temporary until upload and publication are both
   confirmed; **Server Audio** retains history and manages server deletion. Existing VoiceRelay local
   audio follows the same cleanup policy after confirmed delivery. Starting the app never downloads models automatically.
3. Choose **Articles** in the status menu. Pick the source once under
   **Settings → General → Reading List**; VoiceRelay then re-reads it
   at startup and every five minutes while the app runs. Pull down in Articles
   to check immediately; opening Articles also checks the source. Troubleshooting
   shows the last successful check and any source error. Discovery is read-only;
   entries persist across relaunch. Selecting entries does not fetch their pages.
4. Select one or several entries (⌘-click or Shift-click), then click **Add to
   Queue** in the toolbar. Selected rows immediately show a *Preparing…* pending
   state while a background task converts them in displayed list order: new
   articles are fetched/extracted and saved with current voice,
   voice and speed; previously saved text is reused without a fetch.
   A failed source becomes a per-entry error in Articles and does not stop the
   remaining additions; saved items remain. There is no required review step.
   Double-click an entry (or use its **Preview Article** menu) to open its page
   in the Article Preview window. **Settings → Troubleshooting** shows the
   Reading List source, its status and diagnostics only.
   Newly generated narration starts with the article title and source and ends
   with a separate **End of article.** paragraph. Existing finalized audio is
   retained until confirmed upload/publication, then its local copy is removed. Article Open Graph/Twitter preview metadata supplies optional
   episode artwork; absent images never block processing. Publisher image URLs
   appear in RSS as `itunes:image`, without downloading or embedding the image.
   Current Overcast supports episode artwork on podcast screens and during
   playback (since 2025.11.1); playlists/widgets keep podcast-level identity.
   See [Overcast's release notes](https://apps.apple.com/us/app/overcast-podcast-app/id888422857)
   and the [Open Graph protocol](https://ogp.me/). Artwork availability, sizing
   and persistence depend on the publisher and player.
5. Open **Server Audio** — it updates automatically — to see episode history,
   duration, size and delivery status. **Published** confirms both the media copy
   and its inclusion in the server feed. Temporary audio is removed at that point,
   including existing VoiceRelay output after confirmed delivery. Listen in Overcast.
   **Show in Finder** is available only for older local copies awaiting cleanup.
   **Upload New Items** appears while shown episodes need upload/publication and
   hides when complete; failures leave it available for retry. A row's × or
   **Remove Selections** retires the episode from the feed before deleting server
   audio. **Reset Server Audio…** confirms removal of every shown episode.
   Pending server removals remain listed until confirmed. Article text and Reading
   List entries are kept. Stop returns interrupted speech to Ready; Quit preserves
   unfinished checkpoints. Missing pending temporary files regenerate from retained
   text under the same GUID and captured voice; failed rows stay manual Retry.

6. Open **Queue** and click **Generate Speech** to process waiting items in
   order; prepared rows show a *Ready* checkmark. The run keeps draining while
   eligible work remains: it waits for in-flight preparations, and articles
   added while speech is already running join the same run without another
   click. Compatible consecutive items share one prepared speech-helper
   session, so the local model does not reload between articles.
   The current-article readout advances through the run. Verified completed items
   leave Queue automatically and remain in Server Audio. The bar also includes each
   article's encoding/publication completion, so it
   reaches 100% only when nothing eligible remains.
   **Stop Generating** abandons only the interrupted article's unfinished work
   and returns its row to Ready; completed audio and the feed are untouched.
   Quit instead retains unfinished checkpoints for resume. Failed items keep
   their checkpoints and need **Retry** on their row, then an explicit run;
   Retry alone starts no speech. A failure does not stop the run — later Ready
   items still process.
   Removing one or more selected rows (their × control, or Remove for a
   selection) preserves saved article text and audio; removing a *Preparing…*
   row cancels its pending add. With zero or one selection the pane shows
   **Reset Queue…**; with two or more it switches to **Remove Selections**.
   Only Reset Queue asks for confirmation and
   clears every queued membership; Reading List entries, saved article text,
   published audio and preferences are preserved either way.
   Double-click a queue row (or use its **Preview Article** menu) to reopen the
   saved article page in the Article Preview window; resolving the URL reads the
   saved snapshot and the preview then fetches the page as it does for Articles.
   Speech-helper failures report a role-specific message; completed chunks are
   retained for resume. Queue and source inventory use the same internal native
   database.

7. **Settings… → Delivery** configures the private podcast upload with one
   **Feed folder URL**, a **Public folder URL**, and channel details.
   Enter the complete HTTPS upload folder supplied by your WebDAV provider,
   for example `https://webdav.example/podcast`. VoiceRelay always uploads
   `feed.xml` in that folder and
   `.m4a` files in its lowercase `audio/` subfolder. Neither name is configurable.
   Common pasted URL variations normalize on leaving the field or taking an
   action: missing HTTPS, surrounding whitespace, spaces/percent-encoded spaces,
   redundant slashes, dot segments, default ports and trailing slashes. A pasted
   `feed.xml` URL also resolves to its containing folder. Credentials and query
   parameters require a brief, field-specific correction; they are never echoed.
   Existing folders are checked first; upload creates missing parents in order.
   The public folder is the website address that serves these same files, which
   can differ from the WebDAV address. **Subscription URL** shows the complete
   derived `…/feed.xml` address read-only; **Copy** puts it on the clipboard for
   your podcatcher. Public audio links always use `…/audio/` beneath that folder.
   Existing settings retain their feed destination and adopt the fixed layout;
   saved local audio uploads again when its destination changes. Old remote
   copies are preserved, and old delete requests never follow a changed host.
   The password persists only in the device-local Data Protection Keychain,
   never in settings files or logs. Save it again when first using this protected
   store. Touch ID, a supported paired Apple Watch, or your Mac password can
   authorize access; macOS chooses the available authentication methods.
   Tests and uploads share a successful unlock until Quit. Opening Settings
   does not query Keychain, and cancelled access is not retried automatically.
   Replacing/removing a credential may require separate macOS confirmation.
   **Test Connection** checks the feed and implicit audio folders read-only.
   It reports readable destinations, not write permission, and creates nothing.
   If a folder is missing but its parent is readable, the result says folders
   will be created on upload. **Upload Now** creates them if permitted.
   Editing settings or saved credentials invalidates the result. **Upload Now**
   retries items blocked by credentials, permissions or remote-size verification
   after you correct them. Uploaded sizes are confirmed using HEAD, with a
   read-only WebDAV file-property check when HEAD cannot confirm the length.
   Use the username required by your provider and a password or app password
   authorized for WebDAV writes. Configure the public HTTPS folder to serve
   the same uploaded files; its path may differ from the upload path because
   the website can publish a subfolder as its root. Follow your provider's
   hosting instructions rather than assuming the two URLs are identical.
   Test Connection checks WebDAV folders; it does not verify public mapping.
   With delivery
   enabled, each verified publication uploads its audio, then the remote feed,
   and retired audio is removed remotely after the feed no longer references
   it — uploads drain automatically after publishing, removals, launch and
   periodic refresh while the app runs.

   **Troubleshooting → Enable debug logging** captures up to 200 delivery events
   in memory for the current app session. **Copy Debug Log** copies the captured
   events; **Clear Log** discards them. Logging defaults off; the toggle persists,
   while events do not. Disabling stops new recording and retains existing events
   until cleared or Quit. Events include request methods, HTTP codes and fixed
   failure categories, never passwords, usernames, URLs, paths, article content,
   authorization headers or server bodies.

While the app is running, new Reading List entries are automatically admitted
and the ready queue is processed without further clicks — set-and-forget
operation. Manual Add to Queue/Generate/Retry remain as overrides. **Stop
Generating** still interrupts the current item and suspends automatic
processing until new work arrives or Generate is pressed; failed rows stay for
explicit Retry and are never silently retried forever. Relaunch re-readies any
interrupted item when automation is enabled.

Finished opaque UUID-named M4A files use app-owned macOS temporary storage, alongside
separate processing/helper scratch. Completed processing scratch is removed after
publication; finished M4A copies remain until byte-confirmed upload and feed
membership, then durable cleanup intent and hash/file-identity checks permit unlink.
Server Audio history remains after unlink. There is no audio-folder preference or
scheduled retention. Earlier VoiceRelay output follows the same confirmed-cleanup
policy; unrelated files and Python/reference output are never adopted or deleted.
The private SQLite index, saved article text and diagnostic RSS stay under
`~/Library/Application Support/VoiceRelayPrototype/SpeechLibrary` for recovery.
If macOS clears unconfirmed output, it is requeued from saved text. A changed upload
destination recreates released bytes using the same GUID; old-host files are kept.
Unfinished server removals remain visible and their remote deletion waits for feed
confirmation. The diagnostic CLI still supports explicit isolated output folders.
Extracted content is rendered as plain text; raw HTML is never rendered as a page.

Processing and delivery are owned by the running app itself, bound to its
lifetime. Closing the status menu or a standalone window keeps current work
running; **Quit** cancels and waits for owned work — that is the stop control,
through either the menu's **Quit VoiceRelay** or standard macOS Quit. Relaunch restores
durable state and resumes owned work. No worker is
enrolled, no live state is adopted, and no feed is uploaded unless delivery is
deliberately configured and enabled in Settings.

The bundle still contains an inactive `VoiceRelayAgent` prototype and its
versioned XPC contract as reference material. Nothing registers, launches or
connects to it; Settings has no agent control and the running app does not
require it. See the dormant-agent note for the retained layout; do not treat it
as required functionality or an enrollment path.

## Build and diagnostic CLI

```sh
cd /path/to/VoiceRelay
swift test
swift build -c release
./scripts/build-app.sh release
```

The optional build script builds through Xcode and copies its signed bundle to
`dist/VoiceRelay.app`, preserving resources, acknowledgements, Keychain
entitlements and the matching provisioning profile. It requires development
signing configured in Xcode. Set `VOICERELAY_SIGNING_IDENTITY` to a specific
identity if needed; ad hoc signing cannot validate protected Keychain access.
Xcode also builds its app bundle directly. Both use the same
shared core and provisional `org.voicerelay.prototype` identity. Quit the previous
app before running another copy. Canvas, GUI, speech/listening and final-context
checks are operator-owned; compilation does not establish those gates.

The CLI is a developer diagnostic surface. TOML import is optional compatibility
support there, not product onboarding. `doctor` defaults to `./config.toml`; other
commands import a profile only with explicit `--config`. Imported files are read-only.

```sh
swift build --product voicerelay
native_bin="$(swift build --show-bin-path)"
"$native_bin/voicerelay" doctor --config "$PWD/config.fixture.example.toml"
"$native_bin/voicerelay" speech-fixture --project-root "$PWD" \
  --directory "$PWD/var/speech-cli-next"
```

`speech-fixture` produces actual speech from the bundled synthetic HTML article.
The removed `fixture` command cannot generate tones. Select an empty or previously
owned speech workspace; existing nonempty directories, tone markers, overlap with
imported live paths, escaped paths and missing initialized media are refused.
Illustrative `.invalid` delivery URLs are never contacted.

For operator-run interruption/recovery, use `--interrupt-after chunk-committed`
and repeat the same command. `--terminate-after` kills only the invoking CLI at
an explicit checkpoint boundary; the owned helper watches parent loss. The
following extended driver executes actual Kokoro and is not an agent-run check:

```sh
swift -I Sources/CSQLite scripts/check-process-recovery.swift "$native_bin/voicerelay" "$PWD"
```

`reading-list --plist` reports only counts. `review-url --url --directory` exports
one private review without speech. Run `voicerelay --help` for current options.

## Runtime, privacy and acceptance

Runtime/model assets remain project-local and ignored: `models/`, `.runtime/`,
`.cache/`, `.venv/`, generated `var/` and application output are not committed.
Source, selection pins, hashed dependency lock and redistribution notices are
versioned. Setup is explicit:

```sh
python3 runtime/kokoro/runtime_setup.py setup --download
python3 runtime/kokoro/runtime_setup.py check
```

No startup/build/check command changes global Python or conda configuration.
No real MLX/Metal model execution or GUI automation is performed by the agent.

The earlier MLX/Metal abort and beta AppKit/linkd messages are tracked in the
validation record. The operator's later speech success does not prove that the
Metal scheme change caused recovery: API Validation was already unchecked.

Open gates include GUI/Canvas of the new settings/library, actual reviewed-article
speech/listening, interrupted/relaunch recovery, long-input memory and packaged
runtime onboarding. Safari permissions must be verified in the actual app context.
Live migration needs reviewed backups;
WebDAV uploads, public media hosting and Overcast need deliberate independent
acceptance before delivery is enabled.

## License

VoiceRelay is licensed under the [GNU Affero General Public License v3](LICENSE).
Third-party dependencies and runtime/model assets retain their own licenses;
see [Acknowledgements](Acknowledgements/Kokoro-Runtime.md) and the notices in
`Acknowledgements/`. Downloaded runtime and model assets are not included in Git.
