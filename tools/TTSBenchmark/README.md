# Swift TTS model benchmark

Standalone developer tooling for local narration model/voice comparisons on Apple
Silicon. It does not change Libro or VoiceRelay settings, model catalogs or audio.
Start with the [design and checklist](../../docs/TTS_MODEL_BENCHMARK_PLAN.md).

Commands below run from the **NarrationApps root**, using the prepared project
dependencies described in [Contributing](../../CONTRIBUTING.md). Swift/Xcode and
the optional Metal Toolchain are required for actual model runs. No Python runtime
is used. The host, reporting and fixture tests do not link MLX.

## Build and test

```sh
bash tools/TTSBenchmark/scripts/test.sh
bash tools/TTSBenchmark/scripts/build.sh
```

The fixture tier uses its own scratch directory, no model files or network, and
preserves the native package lockfile. Run it before the native build, rather than
running both SwiftPM configurations simultaneously. The Release build uses the
same prepared native dependency checkout as the apps. If Xcode's default Metal
shim cannot find an installed compiler, the build script queries the component
and selects it for that command; it does not modify Xcode or project settings.
Native builds enforce this tool's committed package lockfile.

With the current Xcode Swift build engine, the executables are under
`tools/TTSBenchmark/.build/native/out/Products/Release/`. If using another supported
build engine, obtain the directory with `swift build --package-path
tools/TTSBenchmark --scratch-path tools/TTSBenchmark/.build/native -c release
--show-bin-path`.

```sh
bench_bin=tools/TTSBenchmark/.build/native/out/Products/Release
"$bench_bin/tts-benchmark" --help
"$bench_bin/tts-benchmark" inventory
```

## Explicit preparation and comparison

Keep model assets, reference voices and results under ignored `.local/`. Default
preparation downloads roughly 15–25 GB; exact sizes/revisions are recorded in each
snapshot inventory. Allow additional space for builds and generated WAVs.
Preparation does not start inference. It resolves floating candidate references
once, verifies downloaded files against published LFS hashes/Git blob IDs, and
records immutable revisions plus SHA256 inventories. Existing prepared snapshots
are reverified and retained. To change revisions, use a new workspace.

```sh
mkdir -p .local/tts-model-benchmark
"$bench_bin/tts-benchmark" init .local/tts-model-benchmark/matrix.json
"$bench_bin/tts-benchmark" prepare .local/tts-model-benchmark/matrix.json .local/tts-model-benchmark
"$bench_bin/tts-benchmark" preflight .local/tts-model-benchmark/matrix.json .local/tts-model-benchmark
"$bench_bin/tts-benchmark" run .local/tts-model-benchmark/matrix.json .local/tts-model-benchmark .local/tts-model-benchmark/initial "$bench_bin/tts-benchmark-worker"
```

Edit the matrix **before** starting a run to choose profiles, language, licensed
reference inputs, repetitions and bounds. The default includes 12 model/voice
entrants and one explicitly blocked Fish S2 Pro profile. For Fish, supply a
workspace-relative `referenceAudio`, an accurate `referenceText`, and remove its
`blockedReason`. Reference audio is not supplied or selected on the user's behalf.
The default checkpoint set is distinct from newer Pocket small models, Chatterbox
Nano and KittenTTS 2; this tool does not claim support for those releases.

Each active profile runs in one owned worker, serially, behind the shared
background inference lease. The measured process is OS-sandboxed without network
access, including nested tokenizer/codec loads. An incomplete local dependency
fails rather than silently downloading or switching implementations. The default
16 GiB worker-tree budget and 30-minute profile timeout are benchmark-specific;
the apps' approximately 3 GiB limits are unchanged. Larger inputs may need an
explicitly increased timeout or a smaller profile matrix.

No output is normalized, amplified, limited, silence-trimmed, crossfaded or
time-stretched by the benchmark. It writes native-rate Float32 WAVs. Model-native
processing remains part of the selected implementation and is not rewritten.

### Product-reference runs

To compare the accepted app preparation/assembly path, first use a **separate
validation build's** `LibroSpeechWorker`, not an app being tested by the operator:

```sh
product_worker=.build/TTSBenchmarkValidation-20261024/Build/Products/Release/LibroSpeechWorker
"$bench_bin/tts-benchmark-reference" --prepare .local/tts-model-benchmark "$product_worker"
"$bench_bin/tts-benchmark" run .local/tts-model-benchmark/matrix.json .local/tts-model-benchmark .local/tts-model-benchmark/with-reference "$bench_bin/tts-benchmark-worker" "$bench_bin/tts-benchmark-reference" "$product_worker"
```

The preparation command explicitly obtains the product's pinned assets in the
benchmark workspace. Reference measurements include existing IPC, frontend and
assembly costs, as documented per record. They are labelled separately from
direct model calls and do not become duplicate listening entrants. Keep the
worker's colocated libraries/resources intact; passing an arbitrary renamed copy
does not constitute a valid packaged-worker check.

## Preference bracket

```sh
"$bench_bin/tts-benchmark" bracket .local/tts-model-benchmark/initial
```

Open the generated `bracket.html` **in your benchmark run folder** directly in a
browser. The developer source `Sources/BenchmarkCore/Web/bracket-template.html`
is a template and cannot run on its own. If the opening notice stays visible,
check that you opened the generated file and that JavaScript is enabled.
The generated page is a self-contained,
server-free web app: no package installation, external scripts, uploads or network
requests. Keep it beside its generated `bracket-audio/` directory. Choose Prefer A
or Prefer B (or tie/neither/pause), add optional notes, then click Save & continue.
The next pair appears immediately. Only one player runs at a time; audio levels
remain unadjusted. Pause keeps the current pair pending for a later visit.
Audio, preference buttons and notes share aligned edges. Narrow windows stack
the players and controls vertically; no server or frontend build system is needed.

The bracket is blind from the first pair. The page data, progress exports and
audio filenames use anonymous aliases and hashes. Real names stay in the separate
`bracket-identities.json` file. After finishing, Reveal final identities asks you
to select that file; identities are never loaded automatically. Voices may still
be recognizable. The performance report and original run manifests contain names,
so avoid those while listening if you want to preserve blinding.

Progress saves in this browser when local-file storage is available. Use **Save
progress file** periodically and before closing; **Import progress** restores that
JSON backup in another browser or after clearing browser storage. **Copy progress**
provides a text fallback if downloads are unavailable. Storage behaviour for
`file:` URLs varies between browsers, and the app reports storage failures rather
than promising a durable save. Reusing the same page location/browser is simplest.
Opening two copies is supported conservatively: a stale tab cannot silently
overwrite a newer choice. Browser rendering/playback/file permissions remain
operator checks; JavaScriptCore tests exercise the scoring/persistence logic.
An isolated in-memory WebKit fixture checks startup, control alignment and overflow
at desktop and narrow widths without opening recordings or browser profiles.

Previous choices are listed below the players. Revisit resets dependent later
choices and keeps the old history. The seeded bracket uses two-loss elimination,
with a final reset if necessary; a bye is not a listening win. A tie tries another
calibration passage. No performance metric decides a match. Only the designated
first measured warm take is used; timing repeats and product references do not
become additional listening entrants. Additional contenders can be retained after
the bracket finishes. Undecided preferences stay empty until supplied by the user.

### Use browser results with the Swift finalist workflow

Local HTML cannot silently overwrite the project's `bracket.json` across browsers.
Give the exported progress file to the developer/agent, or import it **once** after
listening (rather than entering each choice in the CLI):

```sh
"$bench_bin/tts-benchmark" import-progress .local/tts-model-benchmark/initial /path/to/bracket-progress.json
```

The importer replays the entire history through the Swift bracket engine, verifies
run identity and aliases, rejects stale canonical edits, and retains revisions.
Reimporting the same backup is safe; later backups from the same page can extend
it. Replaced canonical states are preserved in `bracket-import-history/`, including
when explicitly restoring an older backup. CLI `choose`/`revise`/`retain` remain developer alternatives. Regenerating the
page preserves its original audio and compatible browser progress.

## Blind finalist confirmation

After the preliminary bracket finishes, create a matrix of the top choice and
runners-up. This adds a new, coherent approximately 3,700-word original narrative,
uses only held-out text, and increases the timeout for sustained generation:

```sh
"$bench_bin/tts-benchmark" finalists .local/tts-model-benchmark/initial .local/tts-model-benchmark/finalists.json
"$bench_bin/tts-benchmark" run .local/tts-model-benchmark/finalists.json .local/tts-model-benchmark .local/tts-model-benchmark/confirmation "$bench_bin/tts-benchmark-worker"
"$bench_bin/tts-benchmark" blind .local/tts-model-benchmark/initial .local/tts-model-benchmark/confirmation
```

Open `initial/blind/index.html` and record preferences in `initial/blind/ratings.md`.
The finalist timeout is at least two hours per profile and grows from observed
request time per input character, all requested repetitions and 50% headroom.
It is a sizing estimate; review it before running a very slow finalist.
The page and neutral audio filenames omit identities and preliminary placement;
the separate `initial/unblind.json` supplies the mapping when ready. This exercise
can change the preliminary order or leave ties. Voices may still be recognizable.
For a shorter confirmation using just the already rendered held-out paragraphs,
`blind RUN` creates a pack without a separate long-form run. It refuses to replace
an existing pack; preserve or move an old pack explicitly before regenerating.

## Evidence and recovery

`summary.md` and `results.json` retain completed, failed, blocked and interrupted
attempts. Per-attempt directories contain the job, control events, local diagnostic
log, measurements and hashed WAVs. The matrix and worker hash identify a run.
Changing a matrix, executable, build identity or asset inventory requires a new run directory. Rerunning the same
command retains terminal attempts, marks stale running attempts interrupted, and
starts a new owned attempt only for unfinished work. To explicitly retry a failed
profile, make a new run; failed takes remain in the original evidence.

If a configuration fix needs a separate run, `combine OUTPUT RUN RUN [...]`
creates a derived report/listening directory with source receipts, build metadata
and every attempt copied unchanged. Inputs must have identical passages, seeds,
repetition counts and measurement bounds. It refuses two successful attempts for
the same profile ID, so it cannot select a favourable render. A successful corrected
configuration can replace a failed configuration in the effective roster; the old
failure remains visible in `results.json`. Derived comparisons cannot run inference.
For example, after a corrected profile has finished in a separate directory:

```sh
"$bench_bin/tts-benchmark" combine .local/tts-model-benchmark/comparison .local/tts-model-benchmark/initial .local/tts-model-benchmark/corrected
"$bench_bin/tts-benchmark" bracket .local/tts-model-benchmark/comparison
```

Kokoro British voices require `language: "en-gb"` and their pinned British G2P
assets; region mismatches fail validation before loading.

Cold means a fresh process, with filesystem-cache warmth unspecified. Only the
first generation in a session is cold; later unmeasured first-pass requests are
labelled warmup. Warm statistics exclude those requests. Model-call time ends at
materialized PCM, request time ends after WAV writing, and admission wait is
recorded separately. Full product-reference timings have different boundaries.
RTF is generation seconds divided by output seconds; lower is faster. Also inspect
speaking rate, output duration, failures and sample counts before comparing it.
Physical footprint includes sampled owned descendants; MLX allocator peaks are a
separate measure. Neither is a hard whole-system memory ceiling.

The benchmark verifies PCM validity, hashes, source chunk coverage and output/token
bounds where the adapter exposes real generated-token counts. Chatterbox's pinned
info field contains PCM frame count; it is not used as a token count, and its EOS
status is reported as unobserved rather than inferred from audio length.
The utility does **not** prove that every word was spoken correctly. ASR screening
is optional and is not installed/run automatically. Prosody, word errors,
repetitions, consistency and fatigue require listening. No model-quality winner,
human bracket choice or product acceptance is inferred from throughput.

All logs/audio and full local metadata remain private by default. Before sharing
evidence, review diagnostic logs and job files for reference transcripts, paths
and any private inputs you explicitly added. Public model weights and local
evaluation permission do not establish product redistribution rights.
