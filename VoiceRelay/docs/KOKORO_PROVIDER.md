# Kokoro setup and speech pipeline

Updated October 10, 2026. The active engine adapter uses
`mlx-community/Kokoro-82M-bf16` at the revision recorded in
[selection.json](../runtime/kokoro/selection.json), through mlx-audio Python 0.5.7.
The checkpoint contains 548 F32 tensors despite its model name; the adapter does
not cast weights or change model math. Python 3.12.15, dependency hashes, model
revision and voice assets are pinned. The historical Python application and
benchmark checkout are not runtime dependencies. TTS remains replaceable behind
VoiceRelayCore's backend contract.

## Install and check

Install python3, uv, ffmpeg and ffprobe using your normal tool setup. In **General →
Speech setup**, choose **Install Speech Runtime…**, approve the explicit download,
then **Check Speech Runtime**. Bundled immutable setup sources/pins are staged into
`~/Library/Application Support/VoiceRelayPrototype/SpeechRuntime`; no checkout is
required. The selected runtime changes only after successful installation.
Cancel/Quit terminate and join the owned installer process group.

Within the chosen root, `.runtime/python` holds managed Python,
`.runtime/kokoro/.venv` holds packages/G2P assets, `.runtime/cache` holds caches,
and `models/kokoro/<revision>` holds authenticated model/voice assets. Interpreter,
packages, models, caches, notices and installer scratch stay inside that root;
global environments and HOME are unchanged. Existing explicit or legacy checkout
installations remain usable and are not moved or deleted.

For a development checkout installation, run explicitly in Terminal:

```sh
uv --version
python3 runtime/kokoro/runtime_setup.py paths
python3 runtime/kokoro/runtime_setup.py setup --download
python3 runtime/kokoro/runtime_setup.py check
```

Setup deliberately downloads the pinned runtime and assets, including transitive
packages; it can take several minutes. Repeating it synchronizes the owned
installation to the hashed lock. Check/readiness/build/startup never download.
Inference is offline, isolates user-site imports and overrides cache locations.
Missing pronunciation assets/eSpeak fallback fail locally instead of downloading
or skipping unfamiliar words. External runtime/model symlinks are refused; the
owned uv interpreter link is supported.

Setup already includes a pinned Python download catalog, strips conflicting uv
preferences and permits the specific source-only docopt build under the hashed
lock/build constraints. Those earlier development failures require no global
Python/uv changes. If setup fails, capture its sanitized stage/outcome, retry the
explicit installation or check, and use [beta setup tests](BETA_TESTING.md#3-portable-speech-setup-and-relocation).
Do not delete a working runtime merely to rerun a check.

Installed license files and inventory stay with the runtime. See
[Acknowledgements](../Acknowledgements/Kokoro-Runtime.md). Downloaded assets are not
bundled into Git or the app; complete redistribution, fully bundled tools and
notarization remain later release decisions.

## Voices and output

General exposes Language & Region followed by Voice and speed. Defaults are US
English, Heart and 1.0×. Region changes choose Heart or Emma; reselecting the same
region preserves its voice. New admissions capture en-US/en-GB and their choices;
existing queued/recorded items keep theirs.

The curated order follows upstream quality grades with alphabetical ties, reviewed
October 7, 2026. Grades describe training-data quality/quantity, not measured
listener scores. No upstream per-voice popularity metric is available to this
catalogue, and the app collects none. The pinned snapshot supplies all choices:

| Region | Voices in menu order |
| --- | --- |
| US English | Heart, Bella, Nicole, Aoede, Fenrir, Kore, Michael, Puck, Sarah, Alloy |
| UK English | Emma, Fable, George, Isabella, Lewis, Alice, Daniel, Lily |

Additional languages remain deferred. Output is mono 24 kHz AAC-LC/M4A at 96 kbps
from float32 intermediates, retaining original levels/dynamics. No normalization,
gain, limiter or DRC is applied. Gaps are inserted between Swift narration chunks;
Kokoro's internal segments concatenate without extra gaps. Changing voice/speed
requires fresh speech for a meaningful listening comparison.

## Single-worker pipeline

The active drain owns one inference helper and one per-library filesystem lease.
It overlaps at most one pending chunk validation with inference, and one completed
article's FIFO CPU finalization with the next article's speech. Waiting rows stay
Ready/removable until their turn. Compatible consecutive items reuse the prepared
session; late admissions join the drain. Diagnostic boundary fixtures retain
sequential orchestration for deterministic recovery checks.

One CPU thread prepares the next request's pronunciation. Authenticated voice
tensors stay cached; unused token timestamps and per-segment cache resets are
omitted. MLX reusable allocator cache is capped at 256 MiB, separate from active
model memory. Pinned English splitting/G2P, voice weights, speed and sample math
remain unchanged. No second inference worker or streaming AAC stage is enabled.

Native streaming float-WAV validation/assembly checks RIFF bounds and finite
samples; other lossless formats use the FFmpeg fallback. Encode/probe/decode
verification is reused only for matching bytes within an article. Published audio
is preserved; backend/request/encoding fingerprints govern unfinished scratch
reuse and rebuilding under stable episode IDs.

Stop abandons interrupted speech and returns it to Ready while already-started
finalization finishes. Quit cancels/joins both stages and retains checkpoints.
Child tasks stop before scratch cleanup and lease release. A helper session gets
an owned private system-temp directory, removed only after its worker stops.
Persistent assets and installer scratch stay in the selected runtime root.

## Helper contract

KokoroMLXBackend supervises only the selected root's pinned Python with `-I -B` and
provider source. Bounded, versioned JSON lines carry prepare/synthesize requests
and responses over stdin/stdout, with matching request IDs and provenance. There
is no listening port, source text in process arguments or third-party output in
control diagnostics. Preparation verifies pins/assets and materializes the model
once; synthesis returns ordered, nonempty atomic mono float32 WAV artifacts.

Swift rejects provenance mismatches, duplicate files, missing/invalid audio and
traversal/symlink escapes. Preparation and synthesis have separate 180s/600s
deadlines. Cancellation/failure stops the owned process group with TERM then KILL;
a parent-watch thread also stops it if the Swift owner disappears. A prepared
session belongs to a drain, not a persistent service or cross-run model pool.

Captured settings/checkpoints retain article identity and compatible completed
chunks. A policy/backend change can invalidate unfinished output, while published
or integrity-confirmed final media stays intact. Published repeats are not useful
inference benchmarks.

## Timing and listening checks

Use a freshly built signed Release app (`bash scripts/build-app.sh release`) for
performance comparisons; keep voice/speed constant. Enable Troubleshooting debug
logging and clear it before processing 3–5 fresh medium-length articles. Copy the
log promptly after completion: only the newest 200 events are retained.

Queue timing includes cold prepare and shutdown. Pronunciation, inference,
validation, assembly, encoding and delivery overlap; do not sum them as elapsed
queue time. Encoding reports audio seconds and wall time per audio minute.
Finalizer waits include a Ready-item count; zero near the drain's end generally
means CPU finalization remains with no inference work available. Logs contain no
source text, identities, URLs or paths. The October 7 synthetic assembly result
was a stage measurement, not end-to-end speech/listening acceptance; see
[dated evidence](VALIDATION_HISTORY.md#october-7-single-worker-pipeline-optimization).

Listen in Overcast or to explicit fixture output for pronunciation, omissions,
levels, distortion and chunk joins. Check Stop during a later batch and Quit/relaunch
separately. GPU/memory observation, real synthesis and subjective listening remain
operator checks; fixture tones do not establish speech quality.

## Explicit CLI speech and recovery

These commands run actual Kokoro using an already installed checkout runtime and
private isolated output; they do not read Safari, upload or enable automation:

```sh
swift build --product voicerelay
native_bin="$(swift build --show-bin-path)"
"$native_bin/voicerelay" speech-fixture --project-root "$PWD" \
  --directory "$PWD/var/speech-cli-check" --voice af_heart --speed 1.0 \
  --interrupt-after chunk-committed
# Exit 1 at the requested boundary is expected. Resume the same captured attempt:
"$native_bin/voicerelay" speech-fixture --project-root "$PWD" \
  --directory "$PWD/var/speech-cli-check" --voice af_heart --speed 1.0
```

Choose a different empty folder for another voice/speed comparison. A repeat of a
published fixture should synthesize no new chunks. Optional explicit --config is
read-only diagnostic compatibility; it is not app onboarding. CLI output contains
private artifact paths. Abrupt-crash checks with --terminate-after are operator
work; source/build checks do not prove actual Metal responsiveness or parent-loss
cleanup. See [beta acceptance](BETA_TESTING.md).

## Xcode-only Metal failures

The shared scheme disables Metal API Validation for the pinned runtime. An October
3 crash localized an MLX gather failure to Metal debug encoding; later speech
success did not establish this setting as the fix, since the operator reported
API Validation already unchecked. No upstream/model fix is claimed.

If a new failure occurs, record the sanitized stage/exit signal and compare an
explicit isolated Terminal speech fixture with the signed app. Check the current
Run scheme's Metal diagnostics and the corresponding private macOS crash report;
do not assume the old mechanism caused a new failure. No global tools, model pins
or privacy permissions should change without evidence.
