# Kokoro speech provider: development slice and operator checks

## October 7: regional voice menus

General settings has Language & Region (US/UK English) followed by a filtered
Voice menu. New preferences default to US English/Heart. Region changes select
Heart or Emma; re-selecting the current region preserves its selected voice.
The region derives from the persisted voice ID, so earlier Heart, Bella and Emma
preferences remain compatible without a migration. New queue admissions capture
the matching en-US/en-GB code; existing queued and recorded choices are preserved.

The curated catalogue follows the upstream
[Kokoro voice guide](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md),
reviewed October 7, 2026: descending overall quality grade with alphabetical ties.
Those grades estimate training-data quality/quantity, not measured listener scores.
Upstream does not publish per-voice popularity counts; no popularity metric is
invented, collected or fetched. US English shows ten voices: Heart, Bella, Nicole,
Aoede, Fenrir, Kore, Michael, Puck, Sarah and Alloy. UK English has only eight:
Emma, Fable, George, Isabella, Lewis, Alice, Daniel and Lily. All 18 voice packs
already belong to the pinned snapshot and explicit setup's existing manifest.
Other languages remain deferred by user choice; model/runtime/dependency pins,
English pronunciation and original-level 96k AAC are unchanged.

Manual acceptance: quit the old app and open the newly packaged Release bundle.
In General, change US → UK, confirm the voice list changes and Emma is selected,
choose George, close/reopen Settings and relaunch to confirm persistence. Change
back to US and confirm Heart plus ten choices. Generate fresh articles with one
US and one UK voice to check pronunciation/listening; an already queued article
must retain its original voice. Source-only previews include inert default/UK
settings; Canvas, live speech and listening remain operator checks.

## October 7: bounded single-worker optimization

The active app drain has one inference helper and one filesystem speech lease.
It overlaps one chunk's validation/hash/checkpoint with the next inference, and
one completed article's CPU encoding/publication with the next article's speech.
At most two articles are in flight; finalization is FIFO and limited to one.
Waiting rows remain Ready/removable until their speech turn starts. Late
admissions still drain; failed rows still require Retry. Diagnostic fixed-batch
and boundary-interruption fixtures retain deterministic sequential orchestration.

Explicit Stop cancels/discards the interrupted speech item's owned scratch and
returns it to Ready, while an article already handed to finalization finishes
publication. Quit cancels and joins both stages, retaining recoverable checkpoints.
Every child validation/tool task is joined before cleanup and the library lease
is released only after all work ends. Compatible prepared helpers are reused;
CPU failures cannot cancel a later article's active inference.

Kokoro uses the pinned 0.5.7 English splitter/G2P and model inference with the same
voice pack, weights, speed and float samples. One CPU thread prepares at most one
next request's pronunciation. Voice tensors stay cached until their authenticated
voice/manifest files change. Unused token timestamps and per-segment cache resets
are omitted; MLX reusable allocator cache is capped at 256 MiB (active model memory
is separate). Dependencies/model pins remain unchanged. Updating provider.py
changes the existing backend fingerprint, so older unfinished Kokoro chunks may
regenerate once; finalized audio remains intact.

Kokoro float WAVs are validated and copied as native streaming float32, including
finite-sample and RIFF bounds checks. Other lossless formats retain the FFmpeg
fallback. Final mono AAC-LC/M4A remains 96k without normalization or DRC. One full
AAC probe/decode per unique byte content is cached only within the article;
staged/final copies require matching hashes before reuse. Process/pipe waits wake
on completion/readiness while retaining bounded cancellation/deadline checks.

Settings → Troubleshooting → Enable debug logging now records sanitized speech
stage timings as well as delivery events. The session retains the newest 200
entries; no text, identities, paths or URLs enter timing events. `speech timing:
queue` is wall time including cold preparation and shutdown; pronunciation,
inference, validation, encoding and article times overlap and must not be summed
as elapsed queue time. Stage timings are diagnostic, not speech/listening evidence.
Each successfully verified encode also logs audio duration, encoding wall time
and seconds of encoding per audio minute. For example, 14.3 seconds encoding a
600-second file is 1.43 seconds per audio minute. The duration comes from the
existing final-file inspection; no extra tool or audio processing is introduced.
Idle automatic delivery checks reconcile local feed/deletion intent first and
skip credentials and WebDAV when no work is due, including during retry backoff.
Manual Test Connection remains a server probe, and Upload Now keeps its override.
Each locally published article requests delivery immediately, overlapping uploads
with later speech. Requests during a drain coalesce into one follow-up; automatic
requests respect backoff and a queued Upload Now preserves its force override.
Debug logs also show `speech finalizer wait: started` and the measured wait on
acquisition, each with a snapshot of ready queue items. Counts exclude running,
failed/paused and still-preparing items; unavailable diagnostic metadata is
reported as `unknown` and never blocks processing. These extra read-only metadata
checks run only while logging is enabled. A wait with zero ready items near the
end of a queue is ordinarily the remaining CPU finalization, not idle inference
with more work to start. Streaming encoding and extra inference workers remain
deferred.

Isolated validation passed 300 Swift tests, 22 Python tests and the signed Release
build. A synthetic 75-second float-WAV validation/assembly kernel measured 7.85 ms
median versus 101.28 ms for three FFmpeg processes, with identical PCM bytes. This
is a stage comparison, not an end-to-end Kokoro throughput or listening result;
see [the validation record](VALIDATION.md#october-7-single-worker-pipeline-optimization).

### Manual throughput and listening check

1. Quit the old app, then open the signed Release bundle at `dist/VoiceRelay.app`
   (build with `bash scripts/build-app.sh release`). Use Release for performance
   comparisons; keep voice and speed the same between runs.
2. Enable Troubleshooting debug logging and clear the log. Process 3–5 fresh
   medium-length articles in one queue. Existing published audio is reused, so it
   does not measure inference. Observe GPU History in Activity Monitor if useful.
3. After completion, Copy Debug Log immediately. Preserve the final queue time,
   preparation time, inference/validation and PCM assembly/encoding timings,
   including the `speech encoding` duration and seconds per audio minute. The
   first queue includes a model load; distinguish it from steady-state chunks.
   Confirm delivery requests appear before the final queue timing when later
   articles are still processing. Note finalizer wait times and ready counts.
4. Confirm every completed article appears in Saved Audio and listen locally or
   in Overcast for unchanged levels/dynamics. During a later batch try Stop: the
   already-finalizing article may finish, while interrupted speech returns Ready.
   Quit/relaunch should retain/resume unfinished work under the existing automation
   policy. These are operator checks; the agent did not run GUI or real inference.

No two-inference-worker implementation or performance test was added. Remaining
idle time inside the pinned model's synchronous duration/alignment computation
requires measured engine-level evidence before changing model math.


October 2, 2026. This adds an explicitly selected speech fixture to the shared
Swift pipeline. It does not ingest Safari, publish remotely, or enroll a worker.
The app now uses Kokoro exclusively; synthetic audio is confined to tests. The Python helper is an
engine adapter; extraction, narration, state, encoding, RSS, and orchestration
remain Swift services. The historical Python application and benchmark are not
runtime dependencies.

October 3 status: the operator reports setup now succeeds. The agent's offline
`runtime_setup.py check` returned `ready: true` for the pinned project-local
snapshot, validating installed package versions/assets/provenance. This supersedes
earlier missing-runtime/setup-failure states below. It does not establish Metal
inference or listening acceptance by itself. The operator subsequently reports the
speech fixture worked as expected; detailed real-article listening and recovery
remain separate gates. API Validation was already unchecked, so its scheme change
is not established as the reason for recovery.

## Selection evidence

The supplied [benchmark handoff](../../tts-podcast-server/tts-bench/docs/KOKORO_MLX_HANDOFF.md)
and [Phase 2 assessment](../../tts-podcast-server/tts-bench/docs/PHASE2_ASSESSMENT.md)
select `mlx-community/Kokoro-82M-bf16` through **mlx-audio Python 0.5.7**.
The completed full comparison is `2026-10-02T193241.672718Z` (68 successful records);
the completed stress comparison is `2026-10-02T194203.664165Z` (20 successful records).
These remain historical benchmark evidence, not measurements of this app.

| Warm synthesis median, three measured runs | 1,039 words | 4,187 words | Stress sampled RSS |
| --- | ---: | ---: | ---: |
| mlx-audio Python | 13.75 s | 57.39 s | 1,106.30 MiB |
| Standalone Python Kokoro MLX | 24.89 s | 86.82 s | 651.11 MiB |
| mlalma Swift | 25.16 s | 106.33 s | 476.11 MiB |
| mweinbach Swift | 36.60 s | 159.03 s | 804.58 MiB |

The selected stress runs take 56.84–57.84 s for approximately 1,505.825 s of
speech, about 26 times real time. RSS is sampled worker/descendant resident memory,
not total unified/Metal memory. The user's blind listening preference and the
objective benchmark support the selection; no hours-long agent reliability claim
follows from these runs. Benchmark WAV audits and benchmark tests do not establish
VoiceRelay speech, GUI, packaging, or background acceptance.

The model name says `bf16`, but the audited checkpoint stores **548 F32 tensors**.
The adapter verifies the supplied checkpoint/config/af_heart SHA-256 values and
stored dtype; it does not cast the weights. Revision, Python version, package
pins, default voice/speed, and artifact metadata are in
[`selection.json`](../runtime/kokoro/selection.json). The standalone hashed
[`requirements.lock`](../runtime/kokoro/requirements.lock) was exported offline
from the selected dependency graph. Its installation does not consult the benchmark.
The interpreter download URL/build and upstream SHA-256 are pinned separately in
[`python-downloads.json`](../runtime/kokoro/python-downloads.json): CPython 3.12.15,
Apple Silicon, python-build-standalone release `20261001`. This preserves the
benchmark's Python version; it is a managed distribution rather than the
benchmark's Homebrew interpreter. Real runtime validation remains required.

## Storage and explicit setup

All downloaded interpreter, packages, model/voice files, G2P assets, and setup
caches stay inside the selected VoiceRelay project:

```text
VoiceRelay/
  runtime/kokoro/                       versioned source, selection, hashed lock, tests
  .runtime/python/                     uv-managed Python 3.12.15
  .runtime/kokoro/.venv/                pinned inference environment and packaged G2P assets
  .runtime/kokoro/notices/              installed distribution license copies/inventory
  .runtime/cache/                      uv/pip/Hugging Face/XDG caches
  .runtime/{config,data}/              owned config/data paths
  models/kokoro/<pinned-revision>/       model, config, voices, model card, provenance manifest
  models/huggingface/hub/               owned Hub cache
```

Inference helper `TMPDIR` no longer points into `.runtime/tmp`. Each prepared
helper session gets a new private `0700` directory under the app-owned macOS
system temporary root (`FileManager` temporary directory, `VoiceRelayPrototype/
SpeechHelper`), launched with `TMPDIR` set to that child and removed after the
worker stops. The parent root persists; orphaned scratch is left to OS cleanup.
Explicit setup/download scratch, interpreters, models, venvs and all caches stay
project-local as above. Helper scratch outside the project does not remove the
existing Documents access needed to read these runtime/model/cache sources;
no TCC, signing or privacy-approval change was made.

`/models/`, `/.runtime/`, `/.cache/`, and `/.venv/` are ignored by the project's
`.gitignore`; source and pins remain reviewable. This directory currently has no
Git repository, so no staging or commit was performed. Setup does not reuse the
benchmark's virtual environment or global model cache. External runtime/model
symlinks are rejected; uv's interpreter link within `.runtime/python` is allowed.
Normal helper launches override cache paths, isolate Python from user-site imports,
and use offline Hugging Face settings. A missing spaCy model fails locally;
Misaki's spaCy download entry point is disabled during inference. The pinned
Kokoro pipeline must also have its eSpeak fallback; missing fallback fails explicitly
instead of silently skipping unfamiliar words. No startup,
`doctor`, `check`, or fixture action triggers setup/downloads. `HOME` is preserved.

Run in **Terminal**, without sudo:

```sh
cd /path/to/VoiceRelay
uv --version
python3 runtime/kokoro/runtime_setup.py paths
python3 runtime/kokoro/runtime_setup.py setup --download
python3 runtime/kokoro/runtime_setup.py check
```

The first command confirms the installed uv tool. Setup deliberately downloads
Python, the complete pinned dependency set, and the pinned model/voices.
It may take several minutes and substantial disk space; the lock includes
mlx-audio's transitive dependencies, including Torch. Setup is not tied to an
Xcode build phase. A repeat setup retains the existing owned virtual environment
and synchronizes it to the hashed lock. A damaged/incompatible existing environment
can be diagnosed before removing only its project-local `.runtime/kokoro/.venv`.
The actual clean install/download and Metal inference are operator gates; the
agent's offline tests do not prove these commands complete successfully.

### If setup reports `No download found for request: cpython-3.12.15-macos-aarch64-none`

The inspected uv `0.11.7` (April 15, 2026) has a bundled download catalog that only
knows CPython 3.12.13 for this platform. uv freezes that catalog at each release;
the message does not establish that Python 3.12.15 is unavailable upstream.
See [uv's version availability documentation](https://docs.astral.sh/uv/concepts/python-versions/#installing-a-python-version).

Setup now passes the project's checked-in catalog to `uv python install` using
`--python-downloads-json-url`. Its URL and SHA-256 come from the
[upstream 20261001 release](https://github.com/astral-sh/python-build-standalone/releases/tag/20261001).
Before installing, setup checks the catalog against the Python pin, Apple Silicon
platform, release URL and checksum format. The installed uv 0.11.7 successfully
lists this exact download offline with the local catalog. No global uv update,
Python change, Conda change, or shell activation is needed for this fix.

Rerun the same `setup --download` and then `check` commands above. There is no need
to delete the directories created by the failed attempt. Interpreter installation
still uses `.runtime/python` and `--no-bin`; venv creation requires the already
installed managed interpreter and forbids another automatic Python download.
Setup failures now name the stage and exit status (or timeout), instead of only
`CalledProcessError`. The actual archive/package/model downloads and inference
remain unverified until the operator completes setup and the speech checks.

### If venv creation reports `--managed-python` cannot be used with `--python-preference`

This was a setup-script conflict: the script supplied `UV_PYTHON_PREFERENCE=only-managed`
in its child environment as well as `--managed-python` on the venv command.
uv 0.11.7 rejects that combination. The environment preference has been removed;
venv creation still uses `--managed-python`, `--no-python-downloads`, the exact
Python version and project-owned interpreter directory. Package synchronization
still targets only `.runtime/kokoro/.venv/bin/python`. Inherited uv preferences
are stripped, so the fix does not depend on changing global configuration.

The operator's retry installed Python 3.12.15 successfully before this failure.
An offline regression check now creates a temporary venv with the real setup
environment, confirms it uses that project-owned interpreter and reports 3.12.15,
then removes the temporary venv. All 13 setup checks pass. Rerun setup without
deleting the installed interpreter, then run `check` after setup succeeds.
Full wheel/model installation and actual speech remain operator gates.

### If package installation reports `docopt==0.6.2 has no usable wheels`

October 3 correction: the selected dependency graph includes `docopt==0.6.2`
through `num2words`. [PyPI's release metadata](https://pypi.org/pypi/docopt/0.6.2/json)
lists only `docopt-0.6.2.tar.gz`; its SHA-256 exactly matches the existing lock.
The blanket `--only-binary :all:` policy therefore prevented a clean installation.

Setup now adds the specific `--no-binary docopt` exception, preserving wheel-only
installation for every other package and `--require-hashes` for the entire lock.
It also passes the existing hashed lock as `--build-constraints`; docopt's
isolated setuptools build uses the already pinned setuptools version rather than
a floating version. No dependency version or source hash was changed. The sdist,
build environment, generated wheel and caches stay under the project-owned
`.runtime` paths; installed packages remain in `.runtime/kokoro/.venv`.
uv's [per-package override](https://github.com/astral-sh/uv/pull/4067) supports this
exception, and the installed uv 0.11.7 passes the corresponding offline regression.

All **14 setup checks pass**, including a synthetic stdlib-only source archive
that is built and installed under the exception, refusal of an unrelated
source-only package, and wrong-hash rejection. Those synthetic checks establish
the policy, not successful building of the actual upstream docopt release or
completion of the full dependency/model installation. Rerun the same
`setup --download` command without removing the installed interpreter or venv,
then run `check` after setup succeeds. Metal inference and listening remain open.

Setup retains installed package license files and an inventory. The model card
at the pinned revision declares Apache-2.0; mlx-audio 0.5.7 is MIT.
See the [pinned model card](https://huggingface.co/mlx-community/Kokoro-82M-bf16/blob/a71e4d38b236d968966a2002c4c895dbd12b1c3c/README.md)
and [runtime license](https://github.com/Blaizzy/mlx-audio/blob/v0.5.7/LICENSE).
The runtime includes additional libraries and G2P/eSpeak components with their own
licenses. A complete redistribution review, signed helper/runtime packaging, and
relocation remain gates. This development build uses its external project-local
runtime; the runtime/model are not embedded in or downloaded by the app bundle.

## Helper and recovery contract

`KokoroMLXBackend` wraps a serialized supervised executable behind `TTSBackend`.
It launches only the selected project's `.runtime/kokoro/.venv/bin/python -I -B`
and provider source. The worker establishes its own process group before its
versioned hello. Requests and responses are bounded JSON lines on stdin/stdout;
there is no port, article text in arguments, or third-party output in control logs.

Protocol 1 supports `prepare` and `synthesize`. Every response echoes its protocol
and request ID. Preparation verifies package/asset pins and loads/materializes
model parameters once. Each synthesis request carries text, language, voice,
speed, article ID, chunk index, block indices, and its isolated chunk directory.
Responses return matching provenance and an ordered nonempty artifact list.
Swift rejects mismatched provenance, traversal/symlink escapes, duplicate paths,
missing files, and invalid audio; shared ffprobe validates actual lossless metadata.

Kokoro's own token/G2P/splitting logic stays inside the helper. Lazy arrays are
materialized before conversion and completion. Internal chunks concatenate in
order without extra gaps into one atomic mono 24 kHz float32 WAV per Swift request.
Swift then applies the existing request gaps through float32 intermediates,
resampling only to the configured rate, and AAC-LC/M4A (96k app default),
with no normalization, gain adjustment, limiter or DRC. It retains source levels
and dynamics before lossy encoding. It also performs
validation, opaque UUID filenames, and atomic local publication. Supported speech
languages are English (`en`, `en-US`, `en-GB`), with local American/British voice
IDs, finite speed 0.25–4.0. Defaults are `af_heart`, US English, speed 1.0.

Preparation and each synthesis have separate 180 s / 600 s deadlines. Pause/task
cancellation and failure stop the owned helper group with TERM followed by KILL;
a worker owner-watch thread also stops its group if the Swift parent disappears.
Stopping a session also removes only that session's owned temporary directory.
Each coordinator run prepares once and reuses the loaded model for all requests,
then stops it. It is not a persistent agent or a cross-run warm model pool.
Real Metal responsiveness, abrupt-parent-loss cleanup, and long-running memory
behavior still require operator validation.

Chunk fingerprints cover request text/voice/language/settings/provenance, engine
identity, and extraction/narration versions. Engine identity includes the provider
and setup code, full dependency lock, selection, configured voice/speed, voice
bytes, and voice manifest. The encoded checkpoint also fingerprints these inputs.
Incompatible unpublished audio is rebuilt under the existing episode identity;
compatible completed chunks resume. Published episodes retain their original
identity/date/audio, even after backend changes. Old native episode JSON without
the new optional fingerprint still decodes; an unpublished old encoded cache is
revalidated/re-encoded once rather than assumed compatible.

Attempt settings are captured in SQLite. To compare another voice/speed/profile,
choose a new empty speech fixture folder; changing options while resuming does
not rewrite captured settings. Tone and speech workspaces have different ownership
markers, so they cannot be mixed. The synthetic test backends are not speech evidence.

## First user-run speech check in Xcode

1. Complete explicit runtime setup/check once. No reinstall or download is needed
   merely to build the speech-only app changes.
2. Open `VoiceRelay.xcodeproj`, choose **VoiceRelay → My Mac**, build (⌘B), quit
   any previous copy and run (⌘R). Startup performs no inference.
3. Open **Settings… → Speech**. Heart at 1.0× is the default; voice/speed changes
   save automatically. In **Storage → Choose audio folder…**, select/create the
   folder where finished M4A files should be saved. No config file or mode picker.
   The development runtime continues to use the installed project-local runtime.
4. Under **Prototype development → Runtime and sample diagnostics**, click
   **Generate sample speech**. It uses the selected audio folder and internal
   library, with processing files in macOS temporary storage.
5. In the waveform panel, expect **Speech saved locally**, validated M4A and
   isolated local RSS. Click **Inspect → Play speech** and listen to the ordered
   narration, pronunciation, omissions, chunk joins and clipping.
6. Use **Run / Resume Speech** for a repeat. Expect no newly synthesized chunks
   and unchanged episode identity/media. Test Pause/resume if processing lasts
   long enough; record it as untested if the sample finishes first.
7. For real articles, follow [article speech checks](SOURCE_REVIEW.md#step-by-step-xcode-checks).
   Sample speech and selected articles use the same internal library and chosen
   audio destination. Old fixture workspaces remain developer/historical artifacts.

The CLI **speech-fixture** command runs actual Kokoro on the bundled saved article.
The previous tone **fixture** command has been removed. Real-article speech is
available through the reviewed-source app action; the diagnostic CLI review command
still exports only source/semantic/narration material.

```sh
cd /path/to/VoiceRelay
swift build --product voicerelay
native_bin="$(swift build --show-bin-path)"
"$native_bin/voicerelay" speech-fixture --project-root "$PWD" \
  --directory "$PWD/var/speech-cli-fixed" --voice af_heart --speed 1.0
```

Open the reported M4A in Finder and listen. Use a different empty folder if that
name already belongs to a published fixture. Whole-number speeds such as `1.0`
now survive JSON checkpoint decoding: both integer and floating-point numeric
settings are accepted; strings/booleans and out-of-range values are refused.
No setup or model download is needed for this code correction.

For a separate CLI speech/recovery check (the file paths appear in output):

```sh
cd /path/to/VoiceRelay
swift build --product voicerelay
native_bin="$(swift build --show-bin-path)"
"$native_bin/voicerelay" speech-fixture --project-root "$PWD" \
  --directory "$PWD/var/speech-cli-1" --voice af_heart --speed 1.0 \
  --interrupt-after chunk-committed
# Exit 1 at the requested boundary is expected. Resume the same captured attempt:
"$native_bin/voicerelay" speech-fixture --project-root "$PWD" \
  --directory "$PWD/var/speech-cli-1" --voice af_heart --speed 1.0
"$native_bin/voicerelay" speech-fixture --project-root "$PWD" \
  --directory "$PWD/var/speech-cli-1"
```

The first invocation deliberately stops after one committed chunk; the next should
reuse it, and the final published repeat should report zero new synthesis. Optional
`--config /absolute/config.toml` imports read-only settings. Explicit CLI voice/speed
override imported values for a new attempt. `--terminate-after` is now an operator-run speech crash diagnostic;
`--interrupt-after` exercises exception recovery without killing the CLI. No command contacts the
illustrative feed/enclosure URLs.

Record build, GUI/Canvas, setup, CLI speech/recovery, listening, and memory/agent
results separately in `VALIDATION.md`. Existing linkd/Intents and status-item layout
warning evidence remains tracked independently; this change does not claim to fix
those framework warnings. Next gates are real speech completion/listening, then
bounded HTTP/Safari work, followed by the independently managed Swift agent.

## Speech helper aborts under Xcode Metal API Validation

On October 3, the operator's GUI speech attempt reported `Speech helper exited or
closed its control connection`. Three contemporaneous macOS Python crash reports
identify VoiceRelayApp as the parent/responsible process and show **SIGABRT (6)**:
`mlx::core::Gather::eval_gpu` →
`MTLDebugComputeCommandEncoder setBytes:length:attributeStride:atIndex:` →
`MTLReportFailure` → assertion/abort. The installed provider also completes its
initial handshake when run with stdin EOF, without preparation or inference.
This localizes the observed failures to MLX/Metal execution, beyond helper startup.

The stack closely matches [MLX issue #4061](https://github.com/ml-explore/mlx/issues/4061),
which reports empty gather metadata being passed to Metal's `setBytes` and aborting
with API Validation enabled. Our crash reports do not include the assertion text,
so that specific empty-vector mechanism remains an inference. The beta OS may be
a contributing factor; it is not established as the cause. Apple's
[Metal API Validation guide](https://developer.apple.com/documentation/xcode/validating-your-apps-metal-api-usage)
explains how Xcode scheme diagnostics enable this layer.

The shared **VoiceRelay** Run scheme now explicitly disables Metal API Validation
(`enableGPUValidationMode="1"` is Xcode's disabled value). This is a targeted
development workaround for the pinned external runtime, **not an MLX bug fix or
verified speech completion**. It does not disable Swift/native safety checks,
change model/dependency pins, download assets, or change global Python/Xcode
configuration. Revisit API Validation after a verified upstream fix. The helper
still retains private stdout/stderr isolation; native failure messages now report
the processing stage plus exit status or signal without article text or paths.

Operator retry:

1. Stop the current run in Xcode (⌘.) and quit any separately running VoiceRelay
   copy using its menu-bar **Quit** button.
2. Close and reopen `VoiceRelay.xcodeproj` to reload the shared scheme. Choose
   **VoiceRelay → My Mac** in the toolbar.
3. Choose **Product → Scheme → Edit Scheme…**, then **Run → Diagnostics**.
   Under **Metal**, confirm **API Validation** is unchecked (or **Disabled** if
   this Xcode beta presents a menu). Leave other diagnostics as configured. Close
   the scheme editor. This matters even when **Debug executable** is unchecked.
4. Build (⌘B), then run (⌘R). In the waveform panel, open **Settings…**. Kokoro is the only
   audio provider; saved voice/speed preferences persist. Choose an audio folder
   under **Storage** if needed.
5. Click **Generate sample speech** (or **Saved speech → Resume** for a current
   saved episode). No reinstall or model download is needed for this change.
   Historical fixture resumption remains available in the diagnostic CLI.
6. If it publishes, play the M4A from the selected audio folder. Report
   speech completion and listening separately, including any missing words or
   audible chunk joins. Retry once to confirm an unchanged published episode.
7. If it fails, copy the new complete error from the panel. In Finder, choose
   **Go → Go to Folder…** and enter `~/Library/Logs/DiagnosticReports`; provide
   the newest `python3.12-… .ips` report from that attempt. Do not infer Metal
   validation is still responsible unless the new report confirms it.

If an Xcode-only failure remains, compare the Terminal **speech-fixture** command
above using another empty folder. That comparison runs actual MLX/Metal and is
operator-owned. No GUI automation or actual model execution was performed by the
agent for this diagnosis. Linkd/Intents and menu-bar layout warnings remain separate.
