# Libro

Active development layout: `Libro/` is part of the NarrationApps monorepo.
See the [layout and archival record](../docs/REPOSITORY_LAYOUT.md).

Native batch document narration for Apple Silicon Macs running macOS 27.0+.
Import text, Markdown, RTF, PDF or DRM-free EPUB documents and generate WAV, AAC/M4A/M4B or MP3
using native Kokoro/Soprano speech. This repository owns the GUI, batch/export
workflow and app preferences; common capability lives in the parent repository's
[shared packages](../swift-packages/README.md).

## Build

Building from source requires Xcode with the macOS 27 SDK and Swift 6.2+.
Keep `Libro` beside `swift-packages`; VoiceRelay's repository is not needed.
Xcode references SwiftNarration at the shared root and the separate zero-dependency
AppPresentation package in its subdirectory.

To work on both apps at once, close their standalone project/package windows and
open [NarrationApps.xcworkspace](../NarrationApps.xcworkspace).
Select **Libro** or **VoiceRelay** to run either app, or **Build Both Apps** to
compile both with Debug or Release. See [shared workspace setup](../docs/PACKAGE_BOUNDARIES.md#develop-both-apps-in-one-xcode-workspace).

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
for Xcode package recovery and [dependency provenance](../docs/DEPENDENCIES.md).

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

Text/Markdown accepts legacy encodings through non-lossy native conversion.
If accents or punctuation look wrong, right-click the imported row → Text Encoding
and choose its code page before previewing again; original files are never changed.
EPUB 2/3 follows the book's spine, retaining chapter structure, notes and authored
image descriptions. Protected content is rejected; fixed-layout reading order needs
review. See the shared guide for bounded intake and supported content.

PDFKit text is preferred; unusable/scanned pages use structured Vision OCR.
Authored ALT/captions take precedence; optional brief Apple Intelligence descriptions
run locally when available. Source prose/provenance remain in previews. See
[shared document handling](../docs/DOCUMENT_PROCESSING.md).

Speech has one worker per app. Libro requests interactive priority over background
VoiceRelay at safe boundaries; idle windows do not block background work. Allocator
thresholds/process monitoring are not hard whole-system memory caps. The original
private PDF/Markdown freeze retest remains an operator gate.

Audio is never normalized, volume leveled, gain-adjusted, limited or dynamically
compressed. WAV retains native Float32 samples/rates. AAC podcast/samples use mono
64 kbps/24 kHz; Libro's native-rate Soprano exports retain the model's rate. Completed
recordings are preserved. Mapped kilogram, temperature and explicit-AM/PM spoken forms are now included for
Kokoro, with visible preview notices and unchanged original source. Contextual
homographs remain [follow-up work](../docs/TEXT_NORMALIZATION_RESEARCH.md);
new spoken forms require listening acceptance separately from the accepted pacing.

PDF and EPUB cover art is detected during import for future MP3, M4A and M4B
exports. PDFs use the complete first displayed page, including typography and
vector art, at a bounded resolution; blank/locked pages have no automatic cover.
EPUBs prefer declared cover metadata, then a plausible embedded JPEG/PNG on the
declared cover page or first spine page. No later-chapter or online cover search
is performed, and no automatic square crop cuts off a book's title.

Select one or more queued documents to choose or replace **Cover Art**. Each
document keeps its own cover; selecting multiple documents explicitly applies one
image to that selection. Manual choices win over automatic detection. Remove
also disables automatic re-selection for that document; **Use Book Cover** in
PDF/EPUB context menus restores document-derived art. Artwork uses app-owned
copies, leaving original files and finished exports intact. WAV retains the
selection but does not embed it. An unavailable automatic cover does not block
ordinary import/narration; an explicitly selected missing asset still requires
replacement or removal.

Preview **Contents** navigates authored EPUB navigation, PDF bookmarks and actual
Markdown headings in **Original Source**. Switch to **Narration** to review spoken
content and omission notices. **Settings → General → Document Narration** controls
marked notes and auxiliary sections for future batches; current note placement and
inclusion are the defaults. Bibliography and unclassified prose stay intact.
See the [implemented shared stages](../docs/COVER_ART_AND_NAVIGATION_PLAN.md).

Start with the [documentation index](docs/README.md), [current validation](docs/VALIDATION.md)
and [consolidated operator checklist](../docs/OPERATOR_VALIDATION.md#libro).
The current application has no product CLI or maintained Python runtime.
