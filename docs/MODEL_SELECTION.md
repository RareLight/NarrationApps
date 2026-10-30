# Choosing a narration model

Libro and VoiceRelay use the same native model catalog and selection controls.
Both start with **Kokoro**, the **Recommended** option in the model menu, using
Heart at 1.0×. It balances narration quality, generation speed and low memory use.
Existing saved choices stay unchanged. New models download only when you choose
the **Download Model** button in the **Speech Setup Required** banner (or **Install Model** during onboarding). The app validates and initializes the selected model offline in the background; a green **Ready** label appears beside the Voice Model heading, and **Repair local model** retries the selected model installation when validation fails. Queued VoiceRelay articles and an active Libro batch keep
captured settings when you change your selection.

| Model | Voices and languages | General tradeoff |
| --- | --- | --- |
| Kokoro | 28 English voices, including US and UK voices | Very fast, with low resource demand relative to the larger models |
| Soprano (Libro) | One English voice | Fast and compact; no adjustable speaking speed |
| Qwen3-TTS 1.7B CustomVoice, 8-bit | Ryan, Aiden, Vivian, Serena, Uncle_Fu, Dylan, Eric, Ono_Anna, Sohee; ten narration languages | Expressive narration with more generation time and memory |
| Chatterbox Turbo | Bundled default English voice; optional imported reference voices | Natural English delivery with moderate generation speed |
| Orpheus 3B, BF16 | tara, leah, jess, leo, dan, mia, zac, zoe; English | Expressive voices with slow generation and high memory demand |

Qwen supports English, Chinese, Japanese, Korean, German, French, Russian,
Portuguese, Spanish and Italian. A voice's native accent can still matter in
another language. These are the specific selected checkpoints; other model
variants and hosted providers' voice libraries are not included.

## Stable controls

Model and Voice use the same label and menu columns for every model, including
Chatterbox reference voices. Controls form evenly spaced, left-aligned rows:
Model, Voice, supported model options, then **Play Sample**. Kokoro's Speed value
and arrows stay together beside the label. For Qwen, **Language** chooses the
narration language; the voice's native language is bold and star-marked in that
menu. Hover the native entry for regional detail where applicable. There is no
separate Native row, and changing voices does not override your language choice.
**Delivery** accepts an optional instruction. Hover its label or field for help:
use a short tone or pacing cue, such as “calm and measured”, or leave it blank
for default delivery (128 characters maximum). Chatterbox's import action appears
beneath Voice. Unsupported controls are omitted.

Sample follows the selected model's options, without an empty gap between them.
The section grows or shrinks to fit the visible controls; simpler models have no
reserved blank area. Model and Voice retain their top/left alignment. Compact row
spacing (6pt rows, 4pt columns) follows text size; narrow windows retain scrolling/compact fallbacks.
Libro's inline **Format** label keeps its output dropdown level with the Model
menu, with the same compact 4pt horizontal gap. Its main-window header fits the
controls' height instead of stretching into unused space; narrow layouts place Output format below the voice
controls and scroll either group horizontally when necessary.

## Understand the meters

**Generation speed** estimates relative throughput. **Narration quality** is an
initial editorial guide to typical English naturalness, phrasing and consistency.
More fill means a higher tier for either meter. These are static selection guides,
not progress indicators, accuracy guarantees or measurements made on your Mac.
Click **ⓘ** beside the model picker for the description and both meters.
The meters are hidden until opened. Downloaded-model sizes describe storage, not RAM.

No model is loaded, benchmarked or downloaded to display its ratings. Speed varies
with hardware, text, language and settings. Quality can vary by voice. Non-English
quality, Soprano and custom references currently show **Not rated** where comparable
listening evidence is insufficient. Kokoro's upstream training-data grades remain
separately attributed in help; they are not the cross-model quality meter.

**Speaking speed** changes supported Kokoro generation. It is separate from the
model's generation-speed meter. Other models do not present a misleading numeric
speed control. Qwen offers a separate optional delivery instruction.

## Samples and previews

Bundled samples play the same English phrase at recorded speed without loading a
model. There are 47 presets/samples across the catalog. Existing samples remain
unchanged; new samples carry checkpoint and prepared-text provenance. A sample is
not a preview of a different selected language or speed.

Non-English Qwen selections and imported reference voices use a live authored
preview phrase in the selected language, with the normal installed-model and
idle-processing requirements. Live previews stop and join their owned work before
normal narration begins. See [sample provenance](VOICE_SAMPLES.md).

## Model storage

When the selected model has no usable cached files, both apps show a
**Speech Setup Required** banner: above Libro's voice controls, at the top of
VoiceRelay's **Settings → Voice Model**, and in VoiceRelay's workspace notice
area. Its **Download Model** button installs the selected model with byte
progress and cancellation; check/validation phases use their own indeterminate
labels. The banner disappears once installation and its offline check finish,
reappears for another missing selection, and never downloads on its own.
File sizes and deletion are shown only in **Downloaded models**. Imported
read-only folders are managed in Finder.

The trailing **ⓘ** opens the description and speed/quality meters;
there is no permanent stats panel. For cached models, **Download missing files**
in that popover can complete or repair installation, including additional language
resources, without deleting cached weights first. Articles has no model controls.

By default both apps use the pinned `swift-huggingface` library's shared cache:
`HF_HUB_CACHE`, then `HF_HOME/hub`, then `~/.cache/huggingface/hub` on these
non-sandboxed macOS apps. Installation creates the cache when needed and publishes
standard Hub blobs/snapshots, so compatible apps can reuse them. Model loading and
ordinary UI rendering never download anything. Private runtime overlays link to
immutable blobs; generated tokenizer files stay out of the shared snapshots.

**Settings → Models** in Libro and **Settings → Voice Model → Downloaded models** in
VoiceRelay show allocated model bytes on disk and a confirmed trash action in
compact, fixed columns beneath the folder controls. Model names, file sizes and
trash buttons align across rows without stretching to the window edge. Shared
support assets are excluded. Partial downloads can also be deleted; a failed
deletion keeps the cached model visible. Imported folders have no trash button.
**Choose Folder…** sets an
app-specific override; **Use Hugging Face Cache** returns to the default. Explicit
existing folder choices are preserved. Old automatic app-private locations are
no longer the default; their files remain intact and can be selected explicitly.
Changing locations does not move or delete existing assets. Previous automatic
folders were `~/Library/Application Support/Libro/SpeechRuntime` and
`~/Library/Application Support/VoiceRelayPrototype/SpeechRuntime`; select one
explicitly to reuse or manage its old downloads.

Deletion asks for confirmation, removes all revisions of that model in the chosen
cache and its private runtime copies, and is blocked while either app uses that
storage. Other software does not honor this lock: quit other apps using the model
first. Queued work may require the model to be downloaded again. Completed audio,
reference recordings, unrelated repositories and shared support assets are kept.
Sizes exclude retained shared support assets. Imported read-only model folders are
identified separately and managed in Finder.

## Reference voices

For Chatterbox, **Import reference voice…** accepts a five-to-thirty-second mono
or stereo WAV, smaller than 20 MB. Select a recording you are authorized to use.
The apps retain immutable original bytes privately under the shared per-user
`SwiftNarration/ReferenceVoices` Application Support folder, so either app can
select the profile. Nothing is uploaded. The identifier is its content hash;
importing a different clip creates a different profile and never changes an
admitted job's voice. Importing the original bytes again restores the same ID.

Reference recordings are currently retained rather than automatically deleted;
normal library/model cleanup does not remove them. Ordinary VoiceRelay library
backups do not include these recordings or model weights. Keep an authorized
private copy if you need to restore on another Mac. A missing or changed reference
fails clearly instead of substituting the default voice. Custom voice fidelity
requires listening; the quality meter does not rate a new recording.

## Resource requirements and audio

Generation/installation checks require at least 16 GB of system memory for Qwen
and Chatterbox, and 24 GB for Orpheus. These are conservative support guards, not
promises that every workload fits. Larger workers have model-specific footprint
limits. They are unloaded and reaped at utterance boundaries before inference
admission is released, so background work can yield safely to Libro. Reloading and
asset validation add time compared with warm benchmark calls. Kokoro/Soprano's
existing warm-worker behavior remains unchanged.

Speech runs in a private native Swift/MLX helper. There is no Python service, hosted
speech API, automatic model downgrade or automatic voice fallback. Model installation
is separate from publishing configuration.

The pipeline preserves native PCM; it applies no normalization, level adjustment,
limiting or crossfade. The Chatterbox product adapter disables the pinned upstream
output peak normalization and fade. Original benchmark recordings used that
upstream behavior; their files are unchanged. Future benchmark runs use the raw
product PCM policy, so re-listening is appropriate when comparing loudness.
All new models produce 24 kHz mono output; Soprano retains 32 kHz native output.
Existing WAV/AAC/MP3 export and podcast encoding/transcript rules still apply.

See [implementation and validation](MULTI_MODEL_TTS_IMPLEMENTATION_PLAN.md),
[architecture](ARCHITECTURE.md) and [operator checks](OPERATOR_VALIDATION.md).

## Narration preparation

Every model uses semantic phrasing; there is no phrasing switch. Saved planning
choices from older versions remain readable but no longer change preparation.
Model details also contain optional English spoken-form
expansion for native-text models and private chunk retention for review. Qwen
Delivery presets are optional shortcuts to its existing instruction. These choices
are captured for new work; they never change published audio. See
[long-form quality](LONGFORM_QUALITY.md) for scopes, verification, selective repair,
privacy/storage limits and the retired product-pipeline comparison.
