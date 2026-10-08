# VoiceRelay native macOS prototype

VoiceRelay queues Safari Reading List articles and generates local Kokoro speech
with a shared Swift pipeline: semantic extraction, narration, restartable native
SQLite checkpoints, validated mono AAC-LC/M4A and atomic local RSS. Kokoro's saved
article fixture now has operator-confirmed success. **The app and CLI have no tone
mode.** Synthetic audio providers exist only inside automated tests.

The current Slice 3 continuation adds article selection and batch enqueue, a saved
speech library with offline resume, in-app voice/speed preferences, persistent
Reading List entries, and a durable manual speech queue. Normal
app use requires no TOML file or pipeline parameters. Settings offers one audio
folder choice; processing files use macOS temporary storage. Article inspection
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
choose **VoiceRelay → My Mac**, build (⌘B) and run (⌘R). The waveform menu-bar icon
opens a native status menu; no Dock icon or startup window is expected.
Choosing **Articles**, **Queue**, **Saved Audio** or **Settings…** opens and
focuses the corresponding standalone window, which enables the Dock icon and
⌘-Tab entry while any such window is open, including when minimized. The main
window's sidebar switches between **Articles**, **Queue** and **Saved Audio**.
Closing the last standalone window returns to menu-bar-only operation.

1. In **Settings… → General → Speech**, choose Language & Region, then a voice and
   speed. Defaults are US English, Heart and 1.0×. The menu shows ten US or eight
   UK voices ordered by upstream quality grade; changing region picks its
   highest-rated voice. Choices save automatically. Audio defaults are mono 24 kHz AAC-LC at
   96k, original levels/dynamics without normalization or DRC, 0.15-second chunk
   gaps and 1,800-character narration chunks. Processing uses floating-point
   intermediates. Existing finalized audio is preserved; unfinished app work
   adopts the encoding policy while retaining reusable speech chunks.
2. In **Settings… → General → Storage**, click **Choose…** (or **Change…** if
   already set) and select or create the folder where finished audio is saved.
   This is the only output-location control. The folder choice is remembered.
   **Delete audio older than** defaults to **1 month**, with options from 12 hours
   through 6 months, plus Never. Age uses each file's modification date; month
   options use calendar months. While the app is open, cleanup runs on startup,
   automatic library rechecks, retention changes and after processing, plus
   every 15 minutes when idle.
   It deletes only completed native-library audio that is not queued. Expired audio
   leaves Saved Audio and the local feed; saved article text remains for regeneration.
   The development runtime uses its installed project-local location; building
   or opening the app never downloads or starts inference.
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
   speed and audio folder; previously saved text is reused without a fetch.
   A failed source becomes a per-entry error in Articles and does not stop the
   remaining additions; saved items remain. There is no required review step.
   Double-click an entry (or use its **Preview Article** menu) to open its page
   in the Article Preview window. **Settings → Troubleshooting** shows the
   Reading List source, its status and diagnostics only.
   Newly generated narration starts with the article title and source and ends
   with a separate **End of article.** paragraph. Existing finalized audio is
   preserved. Article Open Graph/Twitter preview metadata supplies optional
   episode artwork; absent images never block processing. Publisher image URLs
   appear in RSS as `itunes:image`, without downloading or embedding the image.
   Current Overcast supports episode artwork on podcast screens and during
   playback (since 2025.11.1); playlists/widgets keep podcast-level identity.
   See [Overcast's release notes](https://apps.apple.com/us/app/overcast-podcast-app/id888422857)
   and the [Open Graph protocol](https://ogp.me/). Artwork availability, sizing
   and persistence depend on the publisher and player.
5. Open **Saved Audio** — it updates automatically — and click
   **Show in Finder** on a row to listen with Quick Look (Space) or Finder
   double-click. Each row shows the audio's duration and file size.
   Delivery labels show **Not uploaded**, **Awaiting upload**, **Uploaded ·
   awaiting publication**, **Published**, or **Upload failed**. Published confirms
   both the audio copy and its inclusion in the server feed. With publishing
   enabled, **Upload New Items** appears while shown items still need delivery;
   it remains available for retry after failure and hides once publication is
   confirmed. Automatic delivery continues to work as before.
   A row's × deletes that audio file and retires it from
   the local feed; selecting two or more rows switches the pane control to
   **Remove Selections**, and zero or one shows **Reset Saved Audio…**, the only
   confirmed action, which deletes every shown file. Saved article text and
   Reading List entries are always kept. The progress display disappears when processing
   finishes; completed audio stays in Saved Audio. **Stop Generating** abandons the interrupted article's unfinished work and returns it to Ready; Quit instead preserves unfinished checkpoints. After quit/relaunch,
   **Queue → Retry → Generate Speech**
   uses saved article text and captured settings without fetching again. If macOS
   purges temporary processing files, unfinished audio is regenerated from saved
   text under the same episode identity. Completed audio never needs scratch files.

6. Open **Queue** and click **Generate Speech** to process waiting items in
   order; prepared rows show a *Ready* checkmark. The run keeps draining while
   eligible work remains: it waits for in-flight preparations, and articles
   added while speech is already running join the same run without another
   click. Compatible consecutive items share one prepared speech-helper
   session, so the local model does not reload between articles.
   The current-article readout advances through the run. Verified completed items
   leave Queue automatically and remain in Saved Audio. The bar also includes each
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

Provider-specific setup details are omitted. The provider's published website root can differ from its WebDAV root; map both URLs to the same feed and media files using the provider's instructions.

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

Only finished opaque UUID-named M4A files go in the chosen audio folder. A hidden,
transient audio-only file in that folder provides atomic publication on the same
filesystem; it is removed after publication. Intermediate HTML, JSON, lossless
chunks, encoding files and tool logs use the standard per-user macOS temporary
directory and completed episode work is removed. Inference helpers get a fresh
per-session scratch directory under the same app-owned system temporary root;
it is removed when the helper stops. The private SQLite index,
approved source/text and local diagnostic RSS live internally under
`~/Library/Application Support/VoiceRelayPrototype/SpeechLibrary`; these durable
records are needed for offline recovery and have no folder chooser.

Changing the audio folder affects new episodes. Existing episodes retain their
original destinations, identities and settings; no audio is moved or deleted.
An unavailable/unmounted destination produces an actionable error without
recreating it. Saved Audio lists only existing, accessible finalized files.
Confirmed externally deleted media leaves Saved Audio and the local feed while
saved text, identity and captured settings remain for explicit regeneration.
An unavailable volume, unreadable folder or linked path is never treated as
deletion: its rows stay hidden but recover when the storage returns. Earlier `Articles`/`SpeechFixture` workspaces and their preferences
are preserved as historical data and are not silently adopted. The app has no
sample-speech or Inspect window; fixture generation and snapshot export remain
developer CLI capabilities.
Extracted content is rendered as plain text; raw HTML is never rendered as a page.

Processing and retention are owned by the running app itself, bound to its
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
WebDAV hosting/WebDAV, media hosting, Tailscale and Overcast need deliberate independent
acceptance before delivery is enabled.
