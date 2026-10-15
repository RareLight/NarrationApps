# Bundled voice samples

Both GUIs play the same pre-rendered assets through AVAudioPlayer. Playback never
loads a model, downloads files or starts the speech helper. NativeSpeech owns the
catalog, resource folder and provenance manifest; AudioOutput owns one-at-a-time
playback and completion/error state. AppPresentation retains no narration dependency.

The inventory is Libro's 28 presented English Kokoro voices plus Soprano's single
voice. VoiceRelay exposes 18 of those Kokoro voices. Other upstream languages and
voices are not included. The October 15 accepted-policy recordings use the
operator-selected common phrase:

> Hello, I can narrate everything from short articles to entire ebooks. Let's get started on a new read together!

The preceding voice-specific introductions are retained only in private build
evidence. All 29 current records include a schema-3 prepared-speech plan with
policy, frontend/resource provenance and final utterances. Kokoro uses the accepted
200-phoneme pause profile; Soprano retains its text frontend.

Samples use speed 1.0, mono AAC-LC at 24 kHz and a target 64 kbps. Soprano's 32 kHz
output is converted with the existing native resampler. Encoding applies no gain,
normalization, leveling, limiter or dynamic range compression. The manifest records
each recording's text, engine/voice, settings, pinned model revision and SHA-256.
The current schema-3 manifest also records the shared planner version, dictionary
fingerprint, pronunciation revision, prepared utterances and regional/frontend/
assembly provenance.
`VoiceSample.phrase` reads the bundled manifest so it follows replacement recordings.

## Regenerating assets

From this repository, run:

```sh
./scripts/regenerate-voice-samples.sh "Dr. Smith paid twelve dollars for a new book. Let's read it together!"
```

This launcher builds the **standalone Swift `VoiceSampleGenerator` executable** and
its companion `NarrationSpeechWorker`, then passes exactly one argument: the sample
text. The text is plain text, spoken by every supported voice; no voice-name
substitution, introduction or article sign-off is added. Quote the entire argument
and escape shell metacharacters as needed (for example, `\$12.50` inside double
quotes). Empty text or additional arguments are rejected. Long text uses the apps'
shared narration chunking. The launcher needs Xcode's selected native Swift/Metal
toolchain and prepares the existing pinned source dependencies; it does not install
model weights. Run it after app builds finish.

After the initial build, the Swift executable can also be run directly:

```sh
.build/debug/VoiceSampleGenerator "Your replacement sample text."
```

Keep the companion helper and SwiftPM resource bundles beside the executable.
Re-run the launcher after changing shared code; direct execution uses the last build.
The utility belongs to this source checkout; it locates the shared source resources
from its compile-time source path. It is an unshipped developer tool, not an app
command-line interface, and neither GUI embeds it.

For each engine, it automatically finds an already prepared workspace in sibling
`Libro-TTS`, `~/Library/Application Support/Libro/SpeechRuntime`, or
`~/Library/Application Support/VoiceRelayPrototype/SpeechRuntime` (in that order).
The selected Kokoro workspace must contain all 28 supported voices and the pinned
pronunciation assets; Soprano must also be installed in one of these locations.
For an isolated prepared workspace, set `NARRATION_SAMPLE_WORKSPACE` to its absolute
root path; the utility validates that workspace exclusively instead of falling back
to an app folder. It still accepts exactly one command-line text argument.
Missing/incompatible models produce an actionable error and leave samples unchanged.
There is no implicit model download or fallback engine. Generation runs with network
access denied.

Rendering calls **NarrationPlanner → NativeSpeechSession → NarrationSpeechWorker →
NativeAudio**, the same shared preparation, supervision, inference and encoding
components as the apps. Kokoro uses the existing pinned Misaki/G2P pronunciation
assets and each voice's US/UK locale; Soprano uses its native model text processing.
Changes to these shared implementations flow into subsequent sample generation.
The utility also snapshots the shared user pronunciation dictionary once per run;
its manifest records the rules fingerprint and actual narration chunks.
No separate pronunciation rules or audio-processing implementation is maintained.
Rendering uses one worker, retains the shared memory guard, and uses background inference
priority so Libro's interactive work takes precedence between chunks.

The utility renders and validates every voice in private staging before atomically
replacing `Sources/NativeSpeech/Resources/VoiceSamples` and its manifest. Concurrent
generators are rejected. A failed render, invalid AAC, or cooperative interruption
(Ctrl-C/SIGTERM) preserves the previous complete sample set. An uncatchable crash
can leave an ignored `.voice-samples-*` staging folder beside the source folder;
the prior asset directory remains intact until the atomic exchange commits.

Both apps depend on this single resource folder, so their **next build includes the
replacement samples**, with no manual copying or app-source edits. Existing exported
apps keep their prior recordings. Ordinary builds/tests never regenerate source
samples. Do not add staging WAVs, model weights, private workspace paths or caches.
A catalog/model revision change must include refreshed samples and manifest.

## Validation

`bash scripts/check.sh` includes complete inventory/provenance, native AAC decoding,
rate/hash integrity, shared-planner parity, all-or-nothing replacement, cancellation,
concurrent-writer rejection and original-level/quiet-to-loud ratio checks. The former
four-argument `NarrationNativeCheck ... samples` mode has been replaced by this tool.

To explicitly exercise every real native voice in an isolated temporary directory,
after building the helper:

```sh
VOICE_SAMPLE_NATIVE_CHECK=1 swift test --disable-sandbox --no-parallel --jobs 4 \
  --filter SampleGenerationTests/testNativeCatalogRegenerationWhenExplicitlyEnabled
```

This gate never overwrites source assets or downloads models. Listening, pronunciation
quality and both apps' Play Sample UI remain operator acceptance checks.


The [longform implementation](KOKORO_LONGFORM_IMPLEMENTATION.md) now carries the
exact common spoken projection through helper preparation and rendering. Future
schema-3 manifests include actual prepared utterances and readable regional,
frontend, style and assembly provenance. Existing bundled schema-2 recordings are
preserved until the operator accepts the profile and requests regeneration.
