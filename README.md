# SwiftNarration and AppPresentation

Shared native Swift libraries for document, book and article narration on Apple
Silicon Macs running macOS 27.0+. Libro and VoiceRelay consume these packages
independently; neither app needs the other app's source repository to build.

The current Kokoro baseline is **Heart (`af_heart`), 1.0×**, actual phoneme packing
with a 200-token target and structural pauses. This profile passed operator A/B
listening. Existing saved speeds and admitted jobs retain their captured settings.
Soprano retains its own text frontend. Unit/temperature and contextual homograph
corrections remain [follow-up work](docs/TEXT_NORMALIZATION_RESEARCH.md).

## Packages and ownership

| Package/product | Responsibility |
| --- | --- |
| SwiftNarration / NarrationCore | Semantic documents, narration policy, source mappings, prepared speech contracts |
| DocumentProcessing | Text/Markdown/RTF/HTML/PDF intake, native structured OCR, image descriptions/dedup |
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

## Local development

Keep the shared checkout named `swift-packages`, beside either app repository.
Add its root and `AppPresentation/` as separate local package dependencies in
Xcode; link only the products needed by each target. This is Swift Package Manager
source integration, not a global library installation.

```sh
bash scripts/prepare-dependencies.sh
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
./scripts/regenerate-voice-samples.sh "Your replacement sample text."
```

It reuses the same planner, dictionary, supervised native engine and audio pipeline.
No product CLI, Python runtime or external FFmpeg/ffprobe dependency is maintained.
The fixture worker, speech worker, native-check harness and sample generator are
unshipped engineering tools.

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
