# VoiceRelay native macOS prototype

Slices 1–2 implement a Swift core, SwiftUI menu bar app, read-only configuration import,
and an isolated saved-article → semantic blocks → narration → mock WAV → mono AAC-LC/M4A
→ SQLite → private RSS vertical slice. Mock tones remain the default. The October 2
continuation adds an explicitly selected **Kokoro speech fixture** with an owned
project-local inference runtime. See [setup and step-by-step Xcode speech checks](docs/KOKORO_PROVIDER.md).
The October 3 continuation begins Slice 3 with **Articles…**: read-only Reading
List refresh, one selected URL fetch, plain-text extraction/narration review and
private snapshot export. See [the source-review guide and manual checks](docs/SOURCE_REVIEW.md).
Real-article speech processing and a persistent source queue remain pending.

See [the detailed implementation plan](docs/IMPLEMENTATION_PLAN.md) and
[validation evidence and outstanding gates](docs/VALIDATION.md). This directory is the
canonical root for continued native development; see [the migration record](docs/MIGRATION.md).
The Python application,
customized config, and existing podcast data are reference material and remain untouched.

## Build and run

Requires macOS 27.0+, Xcode with the macOS 27 SDK (Swift 6.2+), and ffmpeg/ffprobe. The inspected Mac already has
these tools. Tone fixtures need no Python inference runtime. Kokoro speech requires
explicit installation of the pinned project-local Python/MLX runtime; source/build
and offline protocol tests use Python for their synthetic helper checks.

### Xcode GUI

Open `VoiceRelay.xcodeproj`, choose the shared **VoiceRelay** scheme and **My Mac**.
Use **Product → Build** (⌘B), **Product → Run** (⌘R), and **Product → Test** (⌘U).
The app appears in the menu bar as a waveform; it has no Dock icon. The scheme
builds an ordinary app bundle and the diagnostic CLI, and tests the shared core.
Xcode resolves the local Swift package and the reviewed dependency versions recorded
in both lockfiles. No developer account is required for local ad hoc signing.

The source navigator includes the app, shared core, tests, configuration example,
packaging, and design docs. Open `Sources/VoiceRelayApp/VoiceRelayApp.swift` and
enable **Editor → Canvas** to inspect the named inert previews, including Kokoro speech. The core is compiled
from the local package; edit its files here rather than duplicating pipeline code
in an Xcode target. GUI/Canvas acceptance is performed manually by the user.

The Xcode bundle and SwiftPM wrapper share `org.voicerelay.prototype`, preferences,
and the default fixture workspace. Quit an earlier copy before running the other.
Both preserve checkpoints; startup does not automatically process an article.

For the current AppKit/Intents launch-warning investigation, use the separate
[status-item diagnostic project and step-by-step guide](Diagnostics/StatusItemRepro/README.md).
It compares a plain window with a minimal menu-bar app without loading VoiceRelay data.

### Command-line build

Run from `/path/to/VoiceRelay`:

```sh
swift package resolve
swift test
swift build -c release
./scripts/build-app.sh release
```

Launch `dist/VoiceRelay.app` manually when ready to inspect it. The Xcode route
does not need `scripts/build-app.sh`; Xcode constructs its own app bundle.

The build script produces a local ad hoc signed app with fixture resources and dependency
acknowledgements. It does not register a background item, request root access, change Caddy,
or configure Tailscale. Do not treat ad hoc signing as stable trusted signing/FDA/Keychain
acceptance. The provisional bundle identity is `org.voicerelay.prototype`.

For a diagnostic CLI and a persisted fixture demonstration:

```sh
swift build
native_bin="$(swift build --show-bin-path)"
"$native_bin/voicerelay" doctor --config "$PWD/config.fixture.example.toml"
"$native_bin/voicerelay" fixture --directory "$PWD/var/fixture"
"$native_bin/voicerelay" fixture --directory "$PWD/var/fixture"
```

The repeat reports zero newly synthesized chunks and preserves the episode UUID/GUID,
publication date, M4A bytes/modification date, and RSS bytes. `doctor` reads the TOML and
checks tool/path presence. It does not open SQLite, ingest Safari, write probes, or contact
delivery endpoints. Its READY entries are local observations; GATE entries are explicit
acceptance limits. A successful diagnostic command does not certify all setup gates.

CLI defaults to `./config.toml` when present; `doctor` requires that file or `--config`.
`fixture` can run without a profile, using safe built-in fixture settings. Missing explicit
configuration is an error. A safe import sample is `config.fixture.example.toml`.

## Configuration and data protection

Select the actual customized `config.toml` in Settings; do not copy example defaults over it.
It remains in the historical checkout; this project contains only a safe synthetic example.
The CLI can read an external profile with an explicit absolute `--config` path.
Relative paths resolve beside that file, `~` expands, and GUI preferences remember only the
selected location and fixture directory. Imported configuration is read-only; no editing or
write-back is implemented. Configured channel metadata, paths, endpoints, audio and narration
values, backend selectors/settings, and optional WebDAV settings remain preserved.

Python module selectors are accepted as legacy profile values, with a notice that no native
adapter exists. Unknown/legacy fields remain in the original file, not repurposed. Native
profiles currently do not apply Python environment overrides; their presence produces a
compatibility notice. Secret environment references are preserved, but Keychain/environment
secret retrieval and WebDAV delivery are deferred. No password is saved or logged.

Every fixture explicitly overrides all writable paths, channel labels, public enclosure/feed
URLs, and backend to the explicitly selected tone/speech fixture. Imported audio/chunk/tool
settings carry through; speech also preserves the selected voice/backend settings.
Illustrative `.invalid` URLs are not contacted. Fixture runs cannot upload, consume the Safari
backlog, or touch the configured live database/media/feed. Native SQLite has its own application
ID and refuses Python/foreign/newer schemas. Live migration/import requires a later backed-up,
reviewed implementation.

Choose a dedicated empty/new fixture directory or an existing marked VoiceRelay fixture
workspace. The app refuses unowned nonempty directories, overlap with configured live
destinations, internal symlinks, missing initialized media storage, and insufficient space.
It will not recreate a missing initialized media directory. The GUI default is a separate
`~/Library/Application Support/VoiceRelayPrototype/Fixture` workspace.

## Inspect and recover

Click **Run / Resume Fixture** explicitly. **Inspect** displays ordered blocks, bounded
narration chunks and their source indices, plus code/table omission notices. Previews use
plain text; extracted HTML is stored privately and is never treated as sanitized HTML.

Artifacts:

```text
fixture/
  .voicerelay-fixture
  private/native.sqlite3              native state and chunk requests/provenance
  private/feed.xml                    canonical isolated RSS
  private/work/<uuid>/                 source, semantic/narration, checkpoints, lossless audio
  .media-staging/<uuid>.m4a            publication staging outside the media root
  media/<uuid>.m4a                    complete validated isolated episode only
```

The coordinator serializes work in an actor and holds an OS writer lock for the complete
mutation run. Completed chunks record backend/request/version fingerprints and SHA-256 hashes.
Interrupted encoding reuses valid chunks; interrupted publication matches placed audio and
commits the same identity/date. Missing local feed is rebuilt from validated committed episodes.
Damaged published media or conflicting files block RSS replacement and need explicit repair.
Completed episodes are immutable; changing a profile/backend does not automatically regenerate
them. A new fixture workspace is the safe way to demonstrate changed settings.

To exercise exceptions and actual SIGKILL restart boundaries:

```sh
"$native_bin/voicerelay" fixture --directory "$PWD/var/recovery" --interrupt-after audio-placed
# Expected exit 1 at the requested boundary; then resume:
"$native_bin/voicerelay" fixture --directory "$PWD/var/recovery"
swift -I Sources/CSQLite scripts/check-process-recovery.swift "$native_bin/voicerelay"
```

The test driver uses fresh temporary workspaces, no customized config, and kills only its
own fixture child. `--terminate-after` is a fixture diagnostic for the five documented
checkpoint boundaries. Unit tests use exception injection separately. These checks do not
simulate physical power loss or establish production helper process-group cleanup.

## Interface and service lifetime

Closing Settings/inspection/popover does not stop an active fixture. **Pause** cancels the
current fixture and its owned audio tool, retaining checkpoints. **Quit** cancels and waits
for owned work before terminating the interface. Reopening does not process automatically;
click Run / Resume to recover persisted fixture work. Remote feed and media-host status are
displayed separately from local artifacts.

The managed agent is not implemented or enrolled in Slices 1–2. There is therefore no
background enable/disable command yet, no persistent XPC listener, and no service to remove.
Slice 4 will add explicit SMAppService registration/unregistration, authorization status,
GUI reconnection, and independent pause/quit semantics. Merely opening this app performs none
of those actions.

Open `VoiceRelay.xcodeproj` in Xcode and inspect the source-local `#Preview` declarations in
`Sources/VoiceRelayApp/VoiceRelayApp.swift`: Idle, Processing, Paused, Permission denied,
Storage missing, and Upload pending. They use synthetic state and inert callbacks. Preview
rendering must be checked in Canvas; a build does not prove it rendered.

## Remaining live acceptance

Safari permission checks belong to Slice 3 and must be repeated for the actual scheduled
executable in Slice 4. An unsandboxed app still needs applicable macOS privacy authorization;
Terminal permission is not evidence for the agent. Verify Keychain retrieval under its final
identity before enabling delivery. No credentials or model downloads are part of startup.

The supplied completed benchmark selects Kokoro via mlx-audio Python. The app's actual
speech/listening, clean runtime install, signed relocation, long-running memory, and
agent-context gates remain open. The mock proves pipeline mechanics; real sources
still need completeness/boilerplate/list/Unicode inspection and listening tests.

Before live delivery, implement and review native state adoption using copies/backups, verify
the mounted media volume and actual Caddy/Tailscale mapping, activate the exact configured
WebDAV file destination and upload secret, intentionally upload a complete candidate feed,
and verify Overcast discovery/download/playback on the Tailnet-connected device. Existing
delivery experiments are historical evidence. Nothing here revalidates those external systems.

## Project-local model/runtime setup

Model/runtime assets are deliberately outside source control: `.gitignore` covers
`models/`, `.runtime/`, `.cache/`, and `.venv/`. Public source/pins stay under
`runtime/kokoro/`. Startup and builds download no model; explicit setup is:

```sh
cd /path/to/VoiceRelay
python3 runtime/kokoro/runtime_setup.py setup --download
python3 runtime/kokoro/runtime_setup.py check
```

Use the installed `uv` tool. This downloads the project's own pinned interpreter,
wheel dependencies, G2P assets, model and voices, and keeps caches inside the project.
Read [the operator guide](docs/KOKORO_PROVIDER.md) before choosing **Kokoro speech**
in Settings and a **new empty speech fixture folder**. The historical Python and
benchmark environments remain untouched; speech and tone fixture markers cannot mix.
