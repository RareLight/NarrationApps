# VoiceRelay

Active development layout: this repository is an independent Git repository nested under `/path/to/NarrationApps`.
See the [layout and archival record](../docs/REPOSITORY_LAYOUT.md).

VoiceRelay turns Safari Reading List articles into a private podcast using local
Kokoro speech and WebDAV publishing. While the macOS app runs, it discovers
articles, prepares saved text, processes the queue and publishes episodes according
to your preferences. Failed items remain available for manual Retry. Safari
bookmarks and Reading List flags are never modified.

The app targets Apple Silicon and macOS 27.0+. Building from source requires
Xcode with the macOS 27 SDK (Swift 6.2+) and the sibling `swift-packages` directory. Speech uses a bundled native Swift MLX
helper with explicitly prepared pinned model assets; Python/uv/FFmpeg are not required.
Audio is mono 24 kHz AAC-LC/M4A at 64 kbps, with original levels and dynamics: no
normalization, gain, limiter or dynamic range compression. Narration opens with
article title/source and ends with “End of article.” Episode dates use Reading List
save dates when available; optional publisher artwork stays external.

## Build and setup

Prepare the common sources with `bash ../swift-packages/scripts/prepare-dependencies.sh`.
Xcode consumes two local packages: SwiftNarration at `../swift-packages` and the
independent AppPresentation package at `../swift-packages/AppPresentation`. Neither
depends on Libro's repository. See [package boundaries and release management](../docs/PACKAGE_BOUNDARIES.md).

For simultaneous Libro/VoiceRelay development, close both standalone project
windows and separately opened package windows, then open
[../NarrationApps.xcworkspace](../NarrationApps.xcworkspace).
Use its **VoiceRelay** scheme to run this app or **Build Both Apps** to build both.
Xcode cannot load the same local package in separate project/workspace windows;
that causes “already opened” and missing-product errors. Both Debug and Release
use the combined workspace. Installed apps can still run independently.
See [shared workspace instructions](../docs/PACKAGE_BOUNDARIES.md#develop-both-apps-in-one-xcode-workspace).

For standalone-project recovery only, close Xcode and run
`bash scripts/resolve-xcode-packages.sh`. For the combined workspace use
`bash ../scripts/resolve-xcode-workspace.sh`, then reopen that
workspace. Neither procedure deletes caches, models or settings.

Copy `Packaging/Signing.example.xcconfig` to the ignored `Signing.local.xcconfig`
at the project root and set your team there. Debug and Release load the local file
automatically. Keep the team assignment in that ignored file; setting it directly
in Xcode can write it back into the shared project. Use
an Apple Development identity and a matching provisioning profile for the Data
Protection Keychain entitlement. Open `VoiceRelay.xcodeproj`, choose **VoiceRelay →
My Mac**, build and run. To package a signed Release build without launching it:

```sh
bash scripts/build-app.sh release
```

The script stages and verifies Xcode's signed bundle before replacing
`dist/VoiceRelay.app`; a failed copy or verification keeps the previous package.
Private signing files, generated output, runtime/model assets and backups are
ignored. Neither building nor starting the app downloads models.

On first launch without a speech model, the speech setup window offers
**Install Speech Model** or **Not Now**. Installation starts only after your choice;
you can cancel or retry without leaving setup. Installed models skip this window
and are checked offline at startup. To install later, use
**Settings → General → Speech setup → Install Speech Model…**.
Installation explicitly downloads verified native model and pronunciation assets;
**Check Speech Setup** loads the installed model offline without generating audio. The managed runtime is under
`~/Library/Application Support/VoiceRelayPrototype/SpeechRuntime`. Existing
checkout installations remain supported. Cancel and Quit join owned setup work;
global environments are unchanged. See [Kokoro setup and pipeline](docs/KOKORO_PROVIDER.md).
The result appears beside Check: Speech setup not checked, Speech setup ready or the failure.
Publishing and source refreshes do not disable speech setup controls; active audio
work and library maintenance do, with a reason shown in General.

**Start VoiceRelay at login** is off by default. Opt in during initial speech setup
or in **Settings → General → Startup**. If macOS requires approval, use **Open Login
Items Settings**. VoiceRelay starts in the menu bar after sign-in, without opening
library/setup windows, and resumes your configured automation. Quit stops the app;
it next starts when you open it or log in again. Turn the option off to stop future
automatic launches. Changes in System Settings are reflected when you return to
Settings. This starts the ordinary app at login, not a service before sign-in.

## Everyday use

**General → Appearance → Text size** adjusts text throughout the library,
Settings, previews, Help and menu popover. Use **⌘+**, **⌘−** and **⌘0** to enlarge,
reduce or reset it. The preference persists; small text stays at least 12 points.

The circular waveform menu opens a compact popover with overall status, **Sync Now**,
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

1. In **General → Speech**, choose Language and region, Voice and speed. Defaults
   are US English, Heart and 1.0×. Speed spans 0.5–2.0× in 0.05 steps;
   existing saved values are preserved. Voice choices are ranked by upstream quality
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

**Podcast Cover** in Publishing accepts a square, opaque JPEG/PNG of at least
1400 pixels per side; larger images are reduced to at most 3000 pixels. VoiceRelay
starts with the bundled icon-derived cover when no cover has been chosen. Replace
it freely, or Remove it to keep the show without art; custom covers and explicit
removals persist across launches. Choose,
Replace or Remove applies to the overall show. Episode pictures still come from
article preview/social metadata. Artwork is verified before the feed references
it; a failed change preserves the previous feed. Cover-only changes do not
regenerate episode audio. The cover is Publishing configuration, separate from
library backups; restoring a library keeps the current cover configuration.

In article previews, **Contents** navigates authored headings or PDF bookmarks;
page-only destinations remain page-only. **General → Document Narration** offers
Notes (Current Placement, End of Document, Omit) and Include auxiliary sections.
These apply to newly queued articles with explicit source semantics. Bibliographies
and unclassified prose remain, source omissions are visible, and existing queued
articles keep their captured preferences. Shared implementation is recorded in the
[cover/navigation stages](../docs/COVER_ART_AND_NAVIGATION_PLAN.md).

Pasted URLs normalize on commit: whitespace, missing HTTPS, spaces/percent escapes,
redundant slashes, dot segments, default ports and trailing slashes are handled.
A pasted feed.xml URL resolves to its parent. Credentials or query parameters
require a field-specific correction and are never echoed in diagnostics.

Passwords persist only in the device-local Data Protection Keychain, accessible
after the first unlock following a reboot, including while the screen is locked.
Background publishing never opens an authentication prompt. For a password saved
by an older build, enter it again and choose **Save Password** once to update its
access policy; macOS may ask for authorization during that explicit Save. Cancelling
preserves the previous item. Successful reads are cached until Quit; opening
Settings does not query Keychain. Passwords never enter preferences or backups.
Keep a stable app signing identity; changing identity/distribution channels can
separately affect Keychain authorization even in Release builds.

**Test Connection** probes folders read-only; it proves neither write permission
nor the public website mapping. A readable ancestor permits a missing-folder
result; uploading creates folders if authorized. Use the popover's **Sync Now**
for a complete manual sync, or **Uploads** for targeted upload retries. Publishing
settings has no upload action. Enabled publishing drains after publication/removal, launch and
periodically while the app runs. Media size and hash are confirmed before feed publication; the uploaded feed is
read back through authenticated WebDAV and its exact contents confirmed.

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

Discarding local audio also removes its matching Queue work; you can add the
article again manually.

For publishing or backup guidance, open **Help → Publishing and Uploads** or
**Help → Library Backup and Restore**. Section ⓘ controls give brief summaries;
**More Help…** opens the corresponding guide. Help content is bundled and offline.

## Private state and backups

The native library remains at
`~/Library/Application Support/VoiceRelayPrototype/SpeechLibrary`. Compatibility
paths and internal preference keys are retained. Clearing Xcode Derived Data does
not erase the library; changing the app bundle identifier changes its preferences
domain. The app owns processing/publishing; no agent or service enrollment exists.
Private legacy environments, customized state and published files are preserved
in their existing locations and never silently imported.

**Troubleshooting → Library backup** exports retained text, inventory, queue,
episode history and delivery bookkeeping using SQLite backup, including WAL
commits. Backups exclude credentials, preferences, audio, scratch and models.
They contain private source content and server information: keep them private.
Restore validates/stages before replacing the library, preserves the previous
library and disables automation/publishing behind **Finish Library Review**.
It does not change Safari, local audio or server files. See [backup/restore checks](../docs/OPERATOR_VALIDATION.md#voicerelay).

**Troubleshooting → Enable debug logging** retains the newest 200 events in memory.
The toggle persists; events do not survive Quit. Copy Debug Log and Clear Log
operate on this session. Logs include sanitized HTTP outcomes/stage timings,
never credentials, URLs, paths, source text, authorization headers or server bodies.

## Speech samples and pronunciation

General's Play Sample/Stop Sample plays the supported voice's bundled recording at
1.0× without loading a model. All samples now use:

> Hello, I can narrate everything from short articles to entire ebooks. Let's get started on a new read together!

Settings → Pronunciation edits one shared Libro/VoiceRelay spelling dictionary.
Use English phonetic spellings and Play to hear a native preview at the selected
voice/speed. Saved samples do not incorporate new overrides. Ordinary narration
captures rules for its work; editing a rule does not rewrite finished recordings.
See [pronunciation](../docs/PRONUNCIATION.md) and
[sample regeneration](../docs/VOICE_SAMPLES.md).

The accepted Kokoro pacing is implemented. Some units/temperatures and contextual
homographs remain [known frontend limitations](../docs/TEXT_NORMALIZATION_RESEARCH.md);
changing speed or voice is not a general correction for those cases.

## Development and validation

The Swift package exposes VoiceRelayCore and the GUI executable; no product CLI
is maintained. Use isolated source/transport/credential fixtures, never the live
library or Safari input. Prepare/run the shared fixtures before app tests:

```sh
bash ../swift-packages/scripts/check.sh
NARRATION_FIXTURE_WORKER="$PWD/../swift-packages/.build/debug/NarrationFixtureWorker" \
  swift test --disable-sandbox --no-parallel --jobs 4
bash scripts/check-packaging.sh
bash scripts/check-docs.sh
```

[Contributing](CONTRIBUTING.md) records engineering conventions. Start with the
[documentation index](docs/README.md), [architecture](docs/ARCHITECTURE.md) and
[current validation](docs/VALIDATION.md). All manual tests and current candidate
paths are in the [single operator checklist](../docs/OPERATOR_VALIDATION.md#voicerelay).
[Release gates](docs/RELEASE_CHECKLIST.md) separate local ad-hoc packaging from
normal team/Keychain, clean-Mac and public distribution acceptance. Automated
fixtures/builds do not establish GUI, listening or real-service behavior.

## License

VoiceRelay is licensed under the [GNU Affero General Public License v3](LICENSE).
Dependencies and runtime/model assets retain their own licenses; see
[Acknowledgements](Acknowledgements/README.md). Downloaded assets are not
included in Git. The native helper/Metal/notices are bundled already; model weights are explicitly
installed. Notarization and public distribution remain separate release gates.
