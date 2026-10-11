# Contributing to VoiceRelay

Read [AGENTS.md](AGENTS.md), [architecture](docs/ARCHITECTURE.md) and the
[current validation record](docs/VALIDATION.md) before making changes. The
[development handoff](docs/DEVELOPMENT_HANDOFF.md) maps components; the
[final polish checklist](docs/FINAL_POLISH.md) tracks approved work.

## Prerequisites and safe checks

Use Apple Silicon, macOS 27+, Xcode with the macOS 27 SDK and Swift 6.2+.
Core audio fixtures need ffmpeg/ffprobe on PATH. Python's standard library is
sufficient for the offline helper and packaging tests; real Kokoro installation
needs python3 and uv and is an explicit operator action. Dependencies are pinned
in Package.swift and both Package.resolved files. Do not update pins incidentally.

From the repository root:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --cache-path "$PWD/.build/swiftpm-cache" \
  --disable-sandbox --skip-update --no-parallel
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s runtime/kokoro/tests
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests
python3 scripts/check-docs.py
bash -n scripts/build-app.sh
git diff --check
```

For focused changes append `--filter testName` to the Swift command. After editing
project.pbxproj, always run `--filter xcodeProjectAppSourcesUseUniqueBuildFileReferences`.
SwiftPM and Xcode compile the same core, but only an Xcode build validates the
application's explicit source references, resources and packaging. A signed build
uses the ignored Signing.local.xcconfig; see [README](README.md#build-and-setup).
Do not launch the app, enable provisioning updates or operate accounts as a test.

Fixtures create dedicated private temporary libraries and inject source readers,
transports, credential stores and speech providers. Never point a fixture at real
Safari, Application Support, published feeds or another application's data. Mock
and synthetic audio validate mechanics, not voice quality. Record GUI/Canvas,
protected Safari, real Keychain, server, runtime downloads and listening separately
in the operator [beta](docs/BETA_TESTING.md) and [UI](docs/UI_ACCEPTANCE.md) checks.

## Ownership and concurrency

AppModel and presentation models are main-actor observable state. Rendering reads
cached results; it must not query Keychain, contact servers or write metadata.
Heavy disk, parsing, audio and subprocess work belongs to the core coordinator or
owned background tasks. Avoid whole-file audio buffers and repeated list scans.
Prefer fresh projections scoped to a render over independently cached indices.

Every owned task has a stored handle, cancellation policy and join path. Quit
cancels and awaits work; window closure does not. Stop and Quit have different
checkpoint semantics. Source reads/commits and settings bookkeeping must be joined
before library replacement. Revision/identity guards reject stale callbacks after
removal, destination edits or restore. Do not add fire-and-forget mutations.

Preserve one inference worker, one bounded CPU finalizer and existing pronunciation
lookahead. Keep synthesis replaceable behind TTSBackend. Do not change model math,
96k AAC-LC/original-level encoding or narration policy as an incidental optimization.
Use Apple's [responsiveness guidance](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
and keep [Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
in navigation/control chrome, with semantic typography and accessibility fallbacks.

## Persistence and publication changes

SQLite WAL is authoritative for inventory, snapshots, queue and episodes. Use
short transactions; retain existing integrity, ownership and file-identity checks.
Bump schema/record versions only for incompatible changes; decode legacy optional
fields, preserve known metadata in stale saves and add old/new round-trip tests.
Library backups use SQLite backup, never raw WAL/database copies. Restore stages
and validates before atomic replacement, retains the old library and preserves the
persistent review gate. Never test restoration against live state.

Publishing confirms media bytes and authenticated feed contents before releasing
local audio or deleting remote copies. Destination changes must not reuse old-host
proofs or deletion intent. A row failure must not stop unrelated work, while unsafe
whole-feed state must block feed replacement/deletes. Keep proof expiry, backoff,
conditional requests and privacy-safe diagnostics. Local discard, source removal
and server retirement have distinct meanings; cover them with isolated regressions.

## Source organization, dependencies and privacy

Keep app presentation in coherent source files with named synthetic inert previews.
New app sources need unique Xcode file/build references as well as SwiftPM discovery.
Keep fixture/CLI coverage when retiring UI entrypoints. Remove abandoned prototypes
rather than bundling dormant executables. Generated products are disposable; live
runtime installations, configuration and library data are not build artifacts.

Keep private endpoints, usernames, credentials, source content, diagnostics, signing
material, models, audio and backups out of Git, including its history. Use synthetic
examples and inspect `git status` before publishing. Keep dependency pins and
redistribution notices. Add a dependency only when it solves a concrete need and
its license, offline behavior and resource packaging are understood.

Behavior changes need focused tests, a concise user/developer documentation update
and a dated validation entry with exact commands, results and unverified gates.
Do not describe compilation as runtime acceptance. Keep historical evidence linked
rather than treating obsolete behavior as current guidance.
