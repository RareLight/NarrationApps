# Libro

Native batch document narration for Apple Silicon Macs running macOS 27.0+.
Import text, Markdown, RTF or PDF documents and generate WAV, AAC/M4A/M4B or MP3
using native Kokoro/Soprano speech. This repository owns the GUI, batch/export
workflow and app preferences; common capability lives in the independent sibling
[swift-packages](../swift-packages/README.md) repository.

## Build

Building from source requires Xcode with the macOS 27 SDK and Swift 6.2+.
Keep `Libro-TTS` beside `swift-packages`; VoiceRelay's repository is not needed.
Xcode references SwiftNarration at the shared root and the separate zero-dependency
AppPresentation package in its subdirectory.

```sh
bash macos/scripts/prepare-dependencies.sh
bash macos/scripts/build.sh build
LIBRO_CONFIGURATION=Release bash macos/scripts/build.sh archive
bash scripts/check.sh
```

Or open `macos/Libro/Libro.xcodeproj` and use the Libro scheme. Source preparation
pins/patches native dependencies; it does not install model weights. Each app embeds
its own signed helper, Metal and notices. Keep model/cache state outside the bundle;
never copy `.build` or DerivedData between machines. See the [native build guide](macos/README.md)
for Xcode package recovery and [dependency provenance](../swift-packages/docs/DEPENDENCIES.md).

## Use

1. Choose existing prepared models or explicitly Install Speech Model when setup
   is needed. Not Now defers setup; successful preparation closes it. With no selected
   workspace, installation uses `~/Library/Application Support/Libro/SpeechRuntime`.
   Check Speech Setup runs offline. British voices may need their regional resources
   installed after selection; models are never silently downloaded during generation.
2. Add documents/folders using Open or Finder drag/drop. Review extracted narration,
   reading order, notes, OCR and description/omission notices. Choose an output
   folder, format and unique names, then Generate Audio.
3. New Kokoro settings use **Heart at 1.0×** and the accepted longform pause profile.
   Explicit settings and active batches remain unchanged. Soprano retains its own
   text frontend; its voice/speed controls are not Kokoro controls.
4. Play Sample uses a bundled recording, works without models and always plays at
   recorded 1.0×. Settings → Pronunciation edits the dictionary shared with VoiceRelay;
   Play there generates a live pronunciation preview with the selected settings.
5. During work, Next Batch Settings and new documents affect subsequent batches.
   Stop preserves completed files; failed/requeued items require the normal next
   batch action. Quit joins owned work. Check Details for actionable errors.

PDFKit text is preferred; unusable/scanned pages use structured Vision OCR.
Authored ALT/captions take precedence; optional brief Apple Intelligence descriptions
run locally when available. Source prose/provenance remain in previews. See
[shared document handling](../swift-packages/docs/DOCUMENT_PROCESSING.md).

Speech has one worker per app. Libro requests interactive priority over background
VoiceRelay at safe boundaries; idle windows do not block background work. Allocator
thresholds/process monitoring are not hard whole-system memory caps. The original
private PDF/Markdown freeze retest remains an operator gate.

Audio is never normalized, volume leveled, gain-adjusted, limited or dynamically
compressed. WAV retains native Float32 samples/rates. AAC podcast/samples use mono
64 kbps/24 kHz; Libro's native-rate Soprano exports retain the model's rate. Completed
recordings are preserved. Known unit/temperature/homograph limitations and their
[next correction stage](../swift-packages/docs/TEXT_NORMALIZATION_RESEARCH.md) are
separate from the accepted speed/pause behavior.

Start with the [documentation index](docs/README.md), [current validation](docs/VALIDATION.md)
and [consolidated operator checklist](../swift-packages/docs/OPERATOR_VALIDATION.md#libro).
The current application has no product CLI or maintained Python runtime.
