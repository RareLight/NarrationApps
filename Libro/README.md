# Libro

Libro turns documents and books into audio files on Apple Silicon Macs running
macOS 27.0 or later. It reads text, Markdown, RTF, PDF and DRM-free EPUB using
Kokoro, Soprano, Qwen3-TTS, Chatterbox Turbo or Orpheus. Your original documents stay unchanged.

## Get started

1. Open Libro. If **Model Setup** appears, use **Choose Custom Model Folder…** for
   existing compatible models or **Install Model**. **Check Model** verifies a
   chosen model offline. **Not Now** lets you explore without installing.
   Setup uses the same compact download flow as VoiceRelay, with progress and cancellation.
   When the selected model is missing, a **Speech Setup Required** banner above the
   main voice controls offers **Download Model** with progress and cancellation.
   File sizes and confirmed deletion are only in **Settings → Models**. The trailing **ⓘ** opens
   the model description and speed/quality meters. Model and Voice menus keep
   their positions when switching models; extra options and **Play Sample** appear
   in compact, left-aligned rows below them. The section shrinks for simpler models.
   The inline **Format** label keeps the output dropdown level with Model; the
   group moves below the voice controls in narrow layouts. Qwen's native language
   is emphasized in the Language menu rather than shown in a separate row.
   Qwen’s **Delivery** label and optional instruction field explain tone/pacing cues
   on hover. Speed’s value and arrows stay beside its label. **Check Speech Setup** in **Settings → Models** checks
   installed models offline.
2. Add files or folders through **Open** or Finder drag and drop. Select a row and
   choose **Preview Selected** to compare **Narration** with **Original Source**.
3. Choose your model, voice, supported speaking speed and output format. Use **Save Location → Browse**
   to choose an output folder, and edit output names in the queue if needed.
4. Press the green **Start** control, or **Start Queue** (⌘⇧G). If files already
   exist, choose **Overwrite Existing**, **Skip Existing** or **Cancel**.
5. Play finished audio from its row or reveal it in Finder.

Fresh settings start with **Kokoro (Recommended)** and **Heart at 1.0×**. Model, voice and speed are remembered for the next launch. Changes made during a
batch apply to later batches.
**Play Sample** plays a bundled recording at 1.0× without loading a model; it does
not preview your current speed or pronunciation overrides.

Model choices share static speed/quality guidance and samples with VoiceRelay.
See [choosing a model](../docs/MODEL_SELECTION.md) for voices, languages, memory
requirements and optional reference recordings.

## Manage the queue

Drag rows to change their order. During a batch, you can reorder its waiting
items; the current item and captured batch membership stay fixed. Documents added
or settings changed during work belong to later work.

- **Pause/Resume** waits at a safe boundary and continues the same partial recording.
- **Skip** asks for confirmation, discards the current item's unfinished output and
  continues. Skipping while paused leaves the next item paused.
- **Stop** asks for confirmation and leaves unfinished items queued for another Start.
- **Queue Again** makes a finished, failed or skipped row eligible again. It does
  not start speech immediately. Re-adding a finished source also queues it again.

Cancel stops an import, including a drop that is still locating its files. Clear
Queue can discard a pending drop before scanning starts; cancelled or replaced
drops cannot add rows later. Replacement scans wait for previous intake work to
finish. Completed files survive Stop and Quit. **Queue Actions** and clickable status
issues show diagnostics. Closing a preview cancels its remaining text analysis.

## Preview and adjust the text

PDF previews appear after a readable initial portion is analyzed: the first 5%
of pages, rounded up, with a maximum of five pages and a minimum of one. More pages
load in the background. Partial previews are labelled; later analysis may change
layout cleanup and notices. Audio generation uses the complete document.

In **Settings → Document**, choose how to read footnotes, extra sections and
academic citations. **Show example** expands an illustration. Experimental PDF
word joining is off by default. Review uncertain layouts, OCR and scientific text
before generating a book. [Narration settings and limits](../docs/NARRATION_GUIDE.md)
explain what these options can and cannot change.

For incorrectly decoded text/Markdown, right-click its row → **Text Encoding**,
choose the encoding and preview again. Source bytes are never converted on disk.
Outputs cannot be placed inside a selected unpacked book folder. If another
file arrives at an unapproved output path during generation, Libro keeps that
file and reports the conflict for review.

EPUB follows the book's reading order and accepts packaged files or unpacked
`.epub` folders. Protected books are rejected; Libro does not remove DRM.

## Covers and audio formats

PDF/EPUB covers are detected during import and appear as small images beside
queue titles. A PDF thumbnail uses its complete first displayed page; EPUB prefers
its declared cover. Detection is optional and does not block ordinary narration.

Select documents and use **Cover Art** to choose, replace or remove artwork.
Applying art to multiple selected rows changes each selected document. Manual
choices win. **Remove** also prevents automatic re-selection; **Use Book Cover**
in a PDF/EPUB context menu restores document-derived art.

WAV preserves native Float32 audio and does not embed a cover. M4A and M4B use
AAC-LC; M4B is an audiobook container. MP3 provides another widely supported
format. MP3/M4A/M4B can embed cover art. Authored Contents navigation in a preview
does not create chaptered audio exports. Audio levels are never normalized or
adjusted. See [audio details](../docs/ARCHITECTURE.md#audio).

## Settings, storage and troubleshooting

**Pronunciation** edits the dictionary shared with VoiceRelay. Its **Play** action
renders a live preview using the selected model, voice and speed; unlike Play
Sample, it requires installed models and idle speech processing.

**General → Appearance** controls text size (also ⌘+, ⌘− and ⌘0).
**Models** lists downloaded models, their disk sizes and deletion controls, plus storage overrides and offline checks. Downloads default to the shared Hugging Face cache; explicit existing folder choices remain in place. See [model storage](../docs/MODEL_SELECTION.md#model-storage). Missing models are not
silently downloaded during narration. **Troubleshooting** owns helper checks and
optional debug logging; Libro logs can contain document text and paths, so keep
them private.

For errors, start with [troubleshooting](docs/TROUBLESHOOTING.md). For deeper
behavior, see [document processing](../docs/DOCUMENT_PROCESSING.md) and
[voice selection](docs/native-kokoro-voices.md).

## Build

Libro is part of the NarrationApps monorepo. Follow the root
[contributor setup](../CONTRIBUTING.md#setup), then open the combined workspace
and select **Libro**. [Native build details](macos/README.md) cover standalone
builds, Archives and Xcode package recovery. No Python runtime, product CLI or
external FFmpeg installation is needed.

[Documentation index](docs/README.md) · [Automated validation](docs/VALIDATION.md) ·
[Operator checks](../docs/OPERATOR_VALIDATION.md#libro)

All models always use semantic phrasing; there is no phrasing switch.
Model details can retain private
chunks for review; Pronunciation Settings contains sentence previews, advanced
scopes and retained-passage checks/repair. These features preserve existing
exports. See [long-form quality](../docs/LONGFORM_QUALITY.md).
