# NarrationApps

This repository owns the combined Xcode workspace, shared documentation/project
scripts, and the SwiftNarration and AppPresentation packages under `swift-packages/`.
It also owns both applications under `Libro/` and `VoiceRelay/`. Each
app can build against the shared packages without the other app's source.
See the [layout and archival record](docs/REPOSITORY_LAYOUT.md).

The apps provide native document, book and article narration on Apple Silicon
Macs running macOS 27.0+. Open [NarrationApps.xcworkspace](NarrationApps.xcworkspace)
from this root for simultaneous Xcode development. Native speech inference uses
the pinned [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) library.

The current Kokoro baseline is **Heart (`af_heart`), 1.0×**, actual phoneme packing
with a 200-token target and structural pauses. This profile passed operator A/B
listening. Existing saved speeds and admitted jobs retain their captured settings.
Soprano retains its own text frontend. Kokoro now expands explicit kilogram,
temperature, AM/PM and letter-A label forms through a source-mapped projection;
that matched listening is operator accepted. Paragraph/soft-hyphen and conservative
PDF layout/flow stages are implemented with B06 operator validation pending. Contextual homographs remain
[follow-up work](docs/TEXT_NORMALIZATION_RESEARCH.md).

## Packages and ownership

| Package/product | Responsibility |
| --- | --- |
| SwiftNarration / NarrationCore | Semantic documents, narration policy, source mappings, prepared speech contracts |
| DocumentProcessing | Text/Markdown/RTF/HTML/PDF/EPUB intake, native structured OCR, image descriptions/dedup |
| NativeSpeech | Pinned asset inventories, speech contracts, voice metadata and bundled samples |
| AudioOutput | Exact Float32 WAV, native encoding/conversion, pause assembly and sample playback |
| ProcessingPipeline | Speech-specific helper supervision, preparation, progress and cross-app admission |
| Pronunciation / PronunciationUI | Shared spelling dictionary, persistence, Settings editor and live previews |
| NarrationUI | GUI-only narration/setup/sample/image controls |
| AppPresentation | Independent, zero-dependency package for typography, text sizing and Settings presentation |

`NativeSpeechEngine` is a helper-only target linking MLX. Each app bundles its own
private worker and Metal resources; its GUI does not link MLX. One resident worker
per app uses the shared inference lease. Libro has interactive priority; VoiceRelay
yields at safe operation/chunk boundaries. An idle Libro does not hold the lease.

Audio is **never normalized or volume leveled**; no gain, compression, limiter,
DRC, trimming or crossfade is added. Speech samples retain their Float32 values.
The podcast/sample AAC-LC profile is mono 64 kbps/24 kHz; Libro's native-rate
exports are described in [architecture](docs/ARCHITECTURE.md).

## Source checkout

Clone `git@github.com:RareLight/NarrationApps.git` once. Both apps and the shared
packages use the containing commit; no submodules or separate app clones are needed.
[DevelopmentBaseline.json](DevelopmentBaseline.json) records component paths and the
verified toolchain. [Migration provenance](docs/MONOREPO_MIGRATION.md) explains the
sanitized history import and local recovery copies. Models, personal documents,
credentials and generated evidence stay outside versioned source.

## Local development

For simultaneous Libro/VoiceRelay development, close their standalone project
windows and open [NarrationApps.xcworkspace](NarrationApps.xcworkspace). It loads
shared local packages once and exposes both app schemes plus **Build Both Apps**.
See [workspace setup and Debug/Release commands](docs/PACKAGE_BOUNDARIES.md#develop-both-apps-in-one-xcode-workspace).

Keep package sources under `swift-packages/`, beside `Libro/` and `VoiceRelay/`.
Add `swift-packages/` and `swift-packages/AppPresentation/` as local dependencies in
Xcode; link only the products needed by each target. This is Swift Package Manager
source integration, not a global library installation.

```sh
bash scripts/develop.sh health
# Only with explicit network authorization:
bash scripts/develop.sh setup --resolve
bash scripts/check.sh
```

Preparation acquires pinned native sources, applies recorded patches and builds
the native MP3 codec. App model downloads require explicit installation; ordinary
builds/startup/generation do not install models. Never copy `.build`, dependency
workspace state or DerivedData between machines.

Both apps use the same [pronunciation dictionary](docs/PRONUNCIATION.md) and
[29 pre-rendered samples](docs/VOICE_SAMPLES.md). The developer-only utility accepts
exactly one text argument and regenerates that shared resource set atomically:

```sh
./swift-packages/scripts/regenerate-voice-samples.sh "Your replacement sample text."
```

It reuses the same planner, dictionary, supervised native engine and audio pipeline.
No product CLI, Python runtime or external FFmpeg/ffprobe dependency is maintained.
The fixture worker, speech worker, native-check harness and sample generator are
unshipped engineering tools.

## Development foundation

The [development foundation checklist](docs/DEVELOPMENT_FOUNDATION_CHECKLIST.md)
and [original implementation request](docs/AGENT_HANDOFF_DEVELOPMENT_FOUNDATION.md) record the
authorized engineering scope and verified local completion. Manifest-aware health/setup,
tiered validation/evidence, CI readiness, canonical regression ownership, app-file
organization, scoped formatting and maintenance procedures are implemented; see
[contributing](CONTRIBUTING.md) and [development gates](docs/DEVELOPMENT.md).
Remote CI activation and product/operator acceptance remain separate.

## Documentation

Start with the [documentation index](docs/README.md), [architecture](docs/ARCHITECTURE.md),
[current status](docs/IMPLEMENTATION_STATUS.md) and [remaining work](docs/IMPLEMENTATION_PLAN.md).
The [operator checklist](docs/OPERATOR_VALIDATION.md) is the only current manual test list.
[Dependency provenance](docs/DEPENDENCIES.md) records exact pins/patches;
[package management](docs/PACKAGE_BOUNDARIES.md) explains independent consumption.
Remote Git/registry releases still require a release-ready dependency strategy;
no publication or registry setup has been performed.

Keep private documents, models, credentials, caches and generated media out of Git.
Original dependency licenses/notices remain applicable; see [provenance](docs/PROVENANCE.md).
