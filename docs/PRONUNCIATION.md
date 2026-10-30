# Shared pronunciation overrides

Both apps have a **Pronunciation** Settings pane. Add a row with **+**, enter the
word and an English phonetic spelling (for example, `SQLite` → `sequel lite`),
then use the row's **Play** button. Select a row and use **−** to remove it.
Valid changes save automatically after a short pause; Save flushes them immediately.
Incomplete/invalid rows show an explanation and leave the last saved dictionary active.
Reload retrieves the shared dictionary and discards local drafts.

Pronunciation is shared across Libro and VoiceRelay for the same macOS user.
It is stored locally at:

```
~/Library/Application Support/SwiftNarration/Pronunciation/overrides.json
```

The folder/file are private to the user. There is no synchronization service or
cloud processing. Writes use an atomic file replacement under a process lock;
stale revisions cannot overwrite another app's changes. When that happens, the
editor asks the user to Reload. A visible editor refreshes when it has no unsaved
changes. Corrupt, unknown-version or oversized files produce an error; they are
never silently reset. Normal app fixtures and Canvas previews use isolated/inert
state and do not read the user's dictionary.

## Matching and narration

Rules match complete words or literal phrases, without regard to capitalization.
They respect Unicode letter/number boundaries; `read` does not match `reader`.
Longer overlapping keys win. All replacements happen in a single pass: with
`read` → `reed` and `reed` → `red`, the original `read` becomes `reed` once.
Keys are literal text, not regular expressions. Duplicate capitalization is not
a distinct rule within the same language/document/model scope. Advanced scopes,
Kokoro phone overrides, sentence previews and retained-passage review are described
in [long-form narration quality](LONGFORM_QUALITY.md).

Keys support up to 120 characters and must contain a letter or number. Phonetic
spellings support up to 160 characters, using ASCII English letters, spaces,
hyphens and apostrophes. Ordinary English spellings reject IPA and other symbols;
advanced Kokoro phone entries use separate aligned vocabulary validation. There are at most
500 entries. An empty dictionary preserves the existing narration path and
checkpoint identity.

Overrides are applied by the common NarrationPlanner **before sentence/chunk
packing**, including article openings, footnotes and closing text. Expansions are
re-chunked to the existing engine limits. Replacement spellings then go through
the normal native model/G2P. Advanced trusted Kokoro phones instead replace the
exact aligned token span and use the existing validated prepared-phoneme path;
other models never receive phone strings as prose.
Original semantic blocks, source files and provenance remain intact. Narration
plans retain source-block indices and note that pronunciation overrides were used.
The matcher enumerates matches incrementally and checks cancellation rather than
materializing a document-sized list of matches.

Libro snapshots the shared rules once at batch start. VoiceRelay snapshots them
when each article's backend is created. Edits affect subsequent narration rather
than changing an in-flight recording halfway through. Rule fingerprints participate
in VoiceRelay's native backend identity and narration version so unfinished work
cannot reuse audio from stale rules. Previously published audio remains unchanged.

The standalone VoiceSampleGenerator also snapshots the shared dictionary once per
invocation. Its manifest includes the rules fingerprint and actual narration chunks;
existing pre-rendered voice samples change only when that utility is explicitly run.

## Live previews

Play renders the original word using the current draft dictionary and the app's
selected voice/model/speed. A US/UK Kokoro voice uses its existing regional G2P;
Soprano uses its own native text processing. A cold model may take a moment to load.
Click the active row's control to stop it. Editing a row, changing voices, leaving
the pane or quitting cancels the preview. One preview runs at a time.

Previews require a prepared model and idle speech processing in that app. Ordinary
narration and runtime installation/checks cancel and join an outstanding preview
before starting their own helper. Quitting also joins owned preview work. The shared
inference lease still gives Libro priority over background VoiceRelay operations.
The native helper retains its normal memory supervision, closes before playback,
and removes its private temporary WAV after completion/cancellation/error.
Missing models are not implicitly downloaded.

Preview WAV uses original Float32 samples and the model's native sample rate.
AVAudioPlayer performs playback; there is no normalization, volume leveling,
gain, limiter or dynamic range compression. Podcast/sample AAC-LC uses mono 64 kbps/24 kHz. Libro native-rate exports
retain the model rate; see [audio contracts](ARCHITECTURE.md#audio).

## Library boundaries

- **Pronunciation**: Foundation/CryptoKit rules, validation, stable fingerprints and
  shared storage. NarrationCore depends on this UI-free target. Helpers and developer
  tools can consume it without SwiftUI, AppKit, MLX or external dependencies.
- **PronunciationUI**: shared SwiftUI editor, draft/save/conflict state and on-demand
  preview lifecycle. It uses ProcessingPipeline, NativeSpeech and AudioOutput, and
  inherits the apps' font environment. Only the GUI targets link it. MLX remains
  exclusively in NativeSpeechEngine inside each app's private helper.

Apps supply their selected voice/workspace/helper, preview admission/priority,
existing-playback coordination, and lifecycle joins. AppPresentation remains an
independent package without narration dependencies. Both libraries are products
of the existing SwiftNarration package and are linked through the same local Xcode
package references; no additional repository or installation is required.

## Validation and operator checks

Automated fixtures cover Unicode/literal/whole-word matching, longest-first and
non-recursive replacement, validation, stable fingerprints, pre-chunking expansion,
original provenance, cross-app edits/conflicts, bounded/corrupt files, persistent
blank rows, preview cancellation and temporary-file cleanup. A coordinator fixture
changes the dictionary after the first document and verifies that the second uses
the original batch snapshot. VoiceRelay fixtures check that changed rules rebuild
unfinished narration and preserve published audio.

From `NarrationApps/swift-packages/`, with both engines explicitly prepared,
opt into their native renderer checks without playing sound:

```sh
NARRATION_PRONUNCIATION_NATIVE=1 swift test --disable-sandbox --no-parallel --jobs 4 \
  --filter PronunciationUITests/testNativePronunciationPreviewRendererWhenExplicitlyEnabled
```

The fixture uses prepared sibling Libro models and temporary output, validates
finite/nonzero Float32 WAV for Kokoro and Soprano, then removes it. Ordinary tests
skip that gate. GUI operation and listening quality remain operator-owned. Current checks are
L04, V04 and B01 in the [consolidated checklist](OPERATOR_VALIDATION.md). They cover
editing/preview, complete-key matching, shared persistence/conflicts and captured
rules across active work; do not maintain a second pending list here.
