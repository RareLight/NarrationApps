# VoiceRelay native macOS prototype

VoiceRelay reviews Safari Reading List articles and generates local Kokoro speech
with a shared Swift pipeline: semantic extraction, narration, restartable native
SQLite checkpoints, validated mono AAC-LC/M4A and atomic local RSS. Kokoro's saved
article fixture now has operator-confirmed success. **The app and CLI have no tone
mode.** Synthetic audio providers exist only inside automated tests.

The current Slice 3 continuation adds speech from a reviewed article, a saved
speech library with offline resume, and in-app voice/speed preferences. Normal
app use requires no TOML file, pipeline parameters or output-folder selection.
The pinned inference runtime still needs explicit development setup; bundled
runtime onboarding, durable Reading List inventory/queue and the managed agent
remain later work.

See [implementation sequence](docs/IMPLEMENTATION_PLAN.md),
[validation and open gates](docs/VALIDATION.md),
[source review and speech checks](docs/SOURCE_REVIEW.md), and
[Kokoro setup](docs/KOKORO_PROVIDER.md). This directory is the canonical native
project. Historical Python code, customized configuration and published data are
preserved in their original locations.

## Xcode and app use

Requires macOS 27.0+, Xcode with the macOS 27 SDK (Swift 6.2+), ffmpeg/ffprobe and
the explicitly installed project-local Kokoro runtime. Open `VoiceRelay.xcodeproj`,
choose **VoiceRelay → My Mac**, build (⌘B) and run (⌘R). The waveform menu-bar icon
opens the panel; no Dock icon or startup window is expected.

1. In **Settings… → Speech**, choose a voice and speed. Defaults are Heart and
   1.0×. Choices save automatically. Audio defaults are mono 24 kHz AAC-LC at
   64k, −16 LUFS, 0.15-second chunk gaps and 1,800-character narration chunks.
2. The development runtime defaults to this project's location. If necessary,
   select it under **Prototype development → Runtime and sample diagnostics**.
   Selection and app startup never download or start inference.
3. Open **Articles… → Review articles**. Choose a Reading List source and refresh,
   or enter one HTTPS URL and click **Review URL**. File selection is remembered;
   Reading List inventory/exclusions remain session-only. Safari is read-only.
4. Inspect the semantic blocks, narration, footnotes and notices. Click
   **Generate speech** explicitly for a readable review. Blocked/login/consent or
   failed extraction reviews cannot be generated. No backlog processing starts.
5. Open **Saved speech**, refresh after completion, and click **Play** or
   **Inspect**. **Pause** preserves checkpoints. After quit/relaunch, **Resume**
   uses the saved source/semantic snapshot and captured settings, without a fetch.
   Published items keep their identity, dates and media bytes on repeat.

Data lives automatically under
`~/Library/Application Support/VoiceRelayPrototype/Articles`. Private source,
semantic text and SQLite are separate from opaque UUID-named audio. The separate
managed `SpeechFixture` directory is used by **Generate sample speech** in Settings.
Old fixture preferences/data are not migrated or deleted. A previous speech fixture
can be selected using the development folder chooser; old tone workspaces are refused.

**Save private snapshot…** remains an optional diagnostic export. It is not needed
for generation or resume. Extracted content is rendered as plain text in the app;
raw source HTML is private material and is not treated as sanitized HTML.

No worker is enrolled, no source is processed automatically, no live state is
adopted and no feed is uploaded. Closing a window keeps current speech running;
Quit cancels and waits for owned work. Runtime relaunch is explicit.

## Build and diagnostic CLI

```sh
cd /path/to/VoiceRelay
swift test
swift build -c release
./scripts/build-app.sh release
```

The optional build script packages an ad hoc signed app with resources and
acknowledgements. Xcode builds its own app bundle directly. Both use the same
shared core and provisional `org.voicerelay.prototype` identity. Quit the previous
app before running another copy. Canvas, GUI, speech/listening and final-agent
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
speech/listening, interrupted/relaunch recovery, long-input memory, packaged
runtime onboarding and the persistent agent. Safari permissions must later be
verified under the scheduled executable. Live migration needs reviewed backups;
WebDAV hosting/WebDAV, media hosting, Tailscale and Overcast need deliberate independent
acceptance before delivery is enabled.
