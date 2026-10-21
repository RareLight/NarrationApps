# Libro development

Follow the current architecture/status and remaining roadmap in the parent NarrationApps
repository, indexed by ../docs/README.md. It supersedes previous CLI/Python work. Both Libro and VoiceRelay use
the shared packages; keep Libro-specific GUI/workflow in this monorepo directory.
Target macOS 27.0 and native Swift/Apple APIs. Initial native engines are Kokoro and
Soprano. Keep MLX linked only into the private native helper, never the GUI. Speech has one
worker only and no serial/parallel UI mode. Libro requests interactive priority
over background VoiceRelay through the shared lease; do not interrupt in-flight
GPU work or change audio levels.

Inspect relevant source/config/docs/tests before changes. Preserve unrelated work,
private data, model caches, finished/published audio and existing user settings.
No maintained Python runtime, product CLI or external FFmpeg/ffprobe dependency.
Use existing Apple frameworks and pinned native FOSS instead of custom substitutes.
Do not normalize, level, compress dynamics, limit or apply gain to generated audio.
WAV retains original Float32 values; AAC uses the operator-selected 64 kbps/24 kHz
podcast profile. Source prose remains intact; semantic omissions/dedup are visible
in narration previews and retain original blocks/provenance.

Run `bash scripts/check.sh` for shared and app-specific fixtures. Prepare native
sources with `bash macos/scripts/prepare-dependencies.sh`. Build/Archive with
`macos/scripts/build.sh`; use LIBRO_CONFIGURATION=Release for release checks.
Read shared dependency provenance before changing pins/patches. Never copy .build
or DerivedData between machines. Shared package bugs/tests belong in ../swift-packages;
app-specific workflow/preferences tests belong in macos/LibroCore/Tests.

Continue successive stages after automated gates pass. Add meaningful regressions
for changed behavior and debug failures systematically. GUI, actual-document freeze
retest, OCR/caption quality, listening, protected-file, live server and signing-account
acceptance are operator-owned; do not operate the GUI or live services. Keep diagnostic
content private/opt-in. Report source/build/test evidence separately from acceptance.

Testing mode: **autonomous** (confirmed October 17, 2026). Run focused isolated
checks automatically; keep operator-owned GUI/listening/live-service gates separate
and do not replace a bundle currently under operator testing.
