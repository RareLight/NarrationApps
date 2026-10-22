# VoiceRelay

VoiceRelay turns Safari Reading List articles into a private podcast on Apple
Silicon Macs running macOS 27.0 or later. It generates speech locally with Kokoro
and publishes to your HTTPS/WebDAV server. Safari entries are read-only.

## Get started

1. Open VoiceRelay and install its speech model when prompted, or defer setup.
   **Play Sample** works without a model; **Check Speech Setup** checks installed
   models offline.
2. In **Settings → General**, choose your Reading List source, voice and automation
   preferences. New settings use Heart at 1.0×.
3. In **Settings → Publishing**, enter your Feed folder URL, Public folder URL,
   channel information and WebDAV credentials. **Test Connection** checks read
   access; successful publishing also needs write permission and a correct public
   URL mapping.
4. Use the menu-bar popover's **Sync Now** to refresh, generate eligible articles
   and publish them. Copy **Subscription URL** from Publishing into your podcast app.

VoiceRelay continues while its windows are closed. **Quit** stops it. Optional
**Start VoiceRelay at login** is off by default and is available during setup and
in **Settings → General → Startup**; it starts the ordinary app after sign-in.

## Know the three library destinations

| Destination | What it shows |
| --- | --- |
| Articles | Reading List entries and a Queue scope for preparation/speech |
| Uploads | Finished local audio awaiting publication or verification/cleanup attention |
| Server Audio | Durable episode history and pending server removals |

Queue removal, local-audio discard, Safari source removal and server removal have
different consequences. The [user guide](docs/USER_GUIDE.md) explains them along
with automation, searches, covers, credentials and private backups.

**Podcast Cover** starts with the bundled VoiceRelay artwork. You can replace it
or remove it. Per-episode artwork remains separate. **Pronunciation** edits the
shared Libro/VoiceRelay dictionary; the [narration guide](../docs/NARRATION_GUIDE.md)
explains live previews, document choices and text-quality limits.

## Build and setup

Both apps are included in the NarrationApps monorepo. Start with root
[contributor setup](../CONTRIBUTING.md#setup), then the VoiceRelay
[signed-build instructions](CONTRIBUTING.md#signed-builds). Use the combined
workspace's **VoiceRelay** scheme. No Python, uv or external FFmpeg installation
is required. Source preparation does not install speech models.

[User guide](docs/USER_GUIDE.md) · [Documentation index](docs/README.md) ·
[Contributing](CONTRIBUTING.md) · [Validation](docs/VALIDATION.md) ·
[Release checklist](docs/RELEASE_CHECKLIST.md)

VoiceRelay is [AGPL-3.0](LICENSE). Dependency and model terms remain applicable;
see [Acknowledgements](Acknowledgements/README.md). Source availability and ad-hoc
builds do not establish notarized distribution or live account acceptance.
