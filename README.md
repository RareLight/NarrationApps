# NarrationApps

Two native text-to-speech apps for Apple Silicon Macs running macOS 27.0 or later.
Speech runs locally using explicitly installed models.

| App | Use it for | Start here |
| --- | --- | --- |
| **Libro** | Turn documents and books into audio files | [Libro guide](Libro/README.md) |
| **VoiceRelay** | Turn Safari Reading List articles into a private podcast | [VoiceRelay guide](VoiceRelay/README.md) |

Libro supports text, Markdown, RTF, PDF and DRM-free EPUB, with WAV, M4A, M4B and
MP3 exports. VoiceRelay reads articles, generates local narration and publishes
through your HTTPS/WebDAV server. It runs in the menu bar and can optionally start
at login. Both apps share pronunciation editing and document narration controls.

## Using the apps

Install a speech model when prompted, or select an existing compatible model
folder. **Play Sample** works before model installation. Model installation is an
explicit download; ordinary startup and narration do not download missing models.

Read the [narration guide](docs/NARRATION_GUIDE.md) for voice previews, footnotes,
citations, PDF word joining, cover art and document-quality limits. Narration
choices preserve original documents and existing recordings. Audio is never
normalized, levelled, limited or given gain.

VoiceRelay needs network access to fetch articles and publish to your server.
Optional archived-article and image retrieval also use the network. Local speech
processing does not make those network operations private to the Mac; see its
[user guide](VoiceRelay/docs/USER_GUIDE.md#privacy-and-backups).

## Building and contributing

This is one monorepo containing both apps and the shared Swift packages. Clone it
once; no app submodules or separate app clones are required:

```sh
git clone git@github.com:RareLight/NarrationApps.git
cd NarrationApps
```

Follow [contributor setup](CONTRIBUTING.md#setup), then open
[NarrationApps.xcworkspace](NarrationApps.xcworkspace). Use **Libro** or
**VoiceRelay** to run an app; **Build Both Apps** compiles both. Close separately
opened projects/packages before opening the combined workspace.

| Task | Guide |
| --- | --- |
| Build, sign or test from source | [Contributing](CONTRIBUTING.md), [development gates](docs/DEVELOPMENT.md) |
| Understand shared code and app boundaries | [Architecture](docs/ARCHITECTURE.md), [package boundaries](docs/PACKAGE_BOUNDARIES.md) |
| Find implemented features and remaining work | [Current status](docs/IMPLEMENTATION_STATUS.md), [roadmap](docs/IMPLEMENTATION_PLAN.md) |
| Validate app behavior manually | [Operator checklist](docs/OPERATOR_VALIDATION.md) |
| Work as an agent | [AGENTS.md](AGENTS.md), then the relevant app/package instructions |
| Find a reference or maintain documentation | [Documentation index](docs/README.md), [documentation policy](docs/DOCUMENTATION.md) |

Shared implementation lives in `swift-packages/`; app workflows remain in
`Libro/` and `VoiceRelay/`. MLX is linked only into private speech helpers, with one
worker per app and Libro priority at safe boundaries. Native inference uses pinned
[mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) dependencies.

The source is [AGPL-3.0](LICENSE). Dependency/model licenses remain applicable;
see [provenance](docs/PROVENANCE.md). Build preparation and model weights are
separate. Keep credentials, personal documents, models, recordings and generated
output out of Git. Binary distribution and independent package releases have
[separate gates](VoiceRelay/docs/RELEASE_CHECKLIST.md).
