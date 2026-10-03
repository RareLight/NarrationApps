# Kokoro speech provider: development slice and operator checks

October 2, 2026. This adds an explicitly selected speech fixture to the shared
Swift pipeline. It does not ingest Safari, publish remotely, or enroll a worker.
The app still defaults to deterministic mock tones. The Python helper is an
engine adapter; extraction, narration, state, encoding, RSS, and orchestration
remain Swift services. The historical Python application and benchmark are not
runtime dependencies.

October 3 status: the operator reports setup now succeeds. The agent's offline
`runtime_setup.py check` returned `ready: true` for the pinned project-local
snapshot, validating installed package versions/assets/provenance. This supersedes
earlier missing-runtime/setup-failure states below. It does not establish Metal
inference or listening acceptance; use the Xcode speech checks in this guide.

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
  .runtime/{tmp,config,data}/           owned temporary/config/data paths
  models/kokoro/<pinned-revision>/       model, config, voices, model card, provenance manifest
  models/huggingface/hub/               owned Hub cache
```

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
Swift then applies the existing request gaps, loudness/resampling, AAC-LC/M4A,
validation, opaque UUID filenames, and atomic local publication. Supported speech
languages are English (`en`, `en-US`, `en-GB`), with local American/British voice
IDs, finite speed 0.25–4.0. Defaults are `af_heart`, US English, speed 1.0.

Preparation and each synthesis have separate 180 s / 600 s deadlines. Pause/task
cancellation and failure stop the owned helper group with TERM followed by KILL;
a worker owner-watch thread also stops its group if the Swift parent disappears.
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

1. Complete the Terminal setup and `check` commands above. If they fail, save the
   command and complete error output before proceeding.
2. Open `VoiceRelay.xcodeproj`. Choose **VoiceRelay → My Mac**, then **Product →
   Build** (⌘B). Quit any previous VoiceRelay copy; choose **Product → Run** (⌘R).
3. Click the waveform in the macOS menu bar, then **Settings…**. Under **Isolated
   demonstration → Fixture audio**, click **Kokoro speech** in the visible
   segmented control. **Mock tones** produces ascending tones; it does not test
   speech. The app starts in mock mode again after relaunch, so make this selection
   for each new run. Use **Select runtime project…** to
   select `/path/to/VoiceRelay`.
4. Choose **Choose fixture folder…** and create/select a new empty folder, for
   example `VoiceRelay/var/speech-gui-1`. Do not select the project itself or a
   previous tone fixture. An imported configuration remains read-only; its audio
   and narration settings carry through, while all output paths/delivery URLs are
   isolated. Legacy non-Kokoro voice IDs may require a separate speech profile.
5. Return to the waveform panel. Confirm it reads **Saved fixture · Kokoro speech**,
   then click **Run / Resume Fixture** explicitly. Expect
   local speech M4A and local RSS completion, with remote feed disabled and worker
   not enrolled. Click **Inspect** and review the ordered blocks and narration.
6. In Finder, open the chosen fixture's `media` folder. Play the single opaque
   `.m4a`. Listen for missing/repeated words, headings/lists/quotes, chunk joins,
   pronunciation, and clipping. A successful build or feed status does not replace
   listening acceptance.
7. Run again. Expect unchanged episode identity and media, with no new synthesis.
   In a second empty speech folder, press **Pause** during processing, then **Run /
   Resume Fixture**. Check retained progress, successful recovery, and normal
   **Quit**. If this short fixture finishes too quickly, record Pause as untested.
8. Relaunch: mock mode is the safe default. Choose speech mode and the same speech
   folder explicitly to resume; app startup performs no inference or downloads.

For the first CLI speech check, use the **speech-fixture** command and a fresh
folder. The **fixture** command always produces mock tones. This reads the saved
built-in article fixture; reviewed network articles are not yet wired to speech.

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
override imported values for a new attempt. `--terminate-after` remains a tone-only
crash diagnostic; speech uses `--interrupt-after` here. No command contacts the
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
4. Build (⌘B), then run (⌘R). In the waveform panel, open **Settings…** and select
   **Kokoro speech** again; relaunch defaults to mock tones. Confirm the runtime
   project is `/path/to/VoiceRelay`.
5. Select the same failed **speech** fixture folder, then click **Run / Resume
   Fixture**. No reinstall or model download is needed for this change. Retained
   checkpoints are validated normally; do not use a tone fixture folder.
6. If it publishes, play the M4A from that folder's `media` directory. Report
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
