# Development gates

Start with [contributor setup](../CONTRIBUTING.md). Commands in this guide run
from the NarrationApps root, except the explicitly identified package harness commands.
Tests use synthetic isolated inputs; no GUI is launched. Setup is the only
network-acquisition entry point. Prepare sources before running gates; no test
runner installs models. Tests/builds run serially at the tier level, with four
compiler jobs. Do not overlap timing-sensitive tests and heavyweight builds.
Explicit setup `--resolve` acquires both the workspace and all three SwiftPM fixture
graphs; an Xcode-only resolution does not populate package-owned checkout state.
Dependency preparation inside full is OS-network-denied and fails closed if
source acquisition is needed. SwiftPM/Xcode validation uses locked versions and
skips updates/automatic resolution. Product tests use isolated fake transports,
not live services. Do not wrap all fixtures in an app sandbox: macOS then requires
bookmark entitlements even for synthetic security-scoped bookmark tests. Native
workers and packaged Metal probes retain their own OS network denial.

## Choose a tier

| Command | Meaning |
| --- | --- |
| `bash scripts/check.sh --tier quick` | Layout, all docs, shell/plist and tooling regressions; no product tests |
| `bash scripts/check.sh --tier quick --scope presentation` | Also AppPresentation tests |
| `bash scripts/check.sh --tier quick --scope shared --filter SpokenFormTests` | Also selected shared tests, not a full-suite pass |
| `bash scripts/check.sh --tier quick --scope libro` | Also LibroCore tests |
| `bash scripts/check.sh --tier quick --scope voicerelay --filter xcodeProjectAppSourcesUseUniqueBuildFileReferences` | Also the VoiceRelay project-reference regression |
| `bash scripts/check.sh` | Full isolated AppPresentation/shared/LibroCore/VoiceRelay core+app suites, preparation, number, packaging and static regressions |
| `bash scripts/check.sh --tier native` | Unavailable (exit 3) until explicit prepared-model/worker arguments are supplied |
| `bash scripts/check.sh --tier release --adhoc --skip-archives` | Routine workspace Debug/Release builds and four bundle/resource/signature/Metal audits |
| `bash scripts/check.sh --tier release --adhoc` | Also each app's individual Archive and archive bundle audits |

Routine development uses the release tier with **--skip-archives**. Archive checks
are useful for archive/distribution packaging changes or an explicit release gate;
the operator normally creates release archives manually. A build-only summary
records `archives` under `unrequestedGates`; it is not archive acceptance.

Scope/filter is quick-only. Filters are Swift test regular expressions. No matches
is a failure; a selected pass is never a full pass. Fixture worker and prepared
codec environment are supplied to affected shared/app suites.
Full retains the existing package/app scripts as owners and runs shared tests once.
Existing explicitly opt-in acoustic tests remain reported skips, not acoustic passes.
Inherited private review/native opt-ins are removed by the tier runner.

Every run creates `.local/validation/<tier>-<id>/summary.json`: the containing monorepo
revision/dirty state (summary schema 2), actual toolchain/SDK/architecture, selection, step kind,
outcome, skips/test observations and evidence paths. Each log retains at most the
last 2 MiB. Output is private/ignored; default runners use only synthetic prose.
An interrupted run remains `running`, not green. Failure stops dependent steps and
records them `not-run`; unavailable native prerequisites return 3. Do not call a
build, fake packaging test or Metal probe a speech/operator acceptance result.

## Build artifact retention and operator candidates

Routine builds reuse `.build/WorkspaceDerivedData`; do not create another full
DerivedData tree for every implementation slice. Keep validation logs, receipts
and fingerprints in `.local/validation/`. When an operator needs a separate
candidate, retain only the complete app bundles and their relevant evidence;
do not copy or retain an entire build cache as the candidate. Never replace or
prune a bundle while it is running or under active operator review. Reuse one
working build cache after review, and remove superseded generated validation
trees once their evidence has been retained. Keep shared dependency checkouts
when pruning so the next build can prepare offline without downloading them.
Source, model storage, user libraries, completed audio and private validation
inputs/outputs are separate from disposable root build intermediates.

The operator builds validation apps in Xcode with the normal signing configuration
(confirmed November 3). Automated intermediate test builds remain authorized, but
handoffs should request that Xcode build, identify the scheme and relevant operator
checks, and keep ad-hoc artifacts separate from signing-sensitive acceptance.

The November 3 operator-authorized cleanup removes superseded root `.build/`
validation trees. Older dated records retain their original paths as historical
evidence, not promises that those generated bundles remain available. The current
preparation candidate remains intact, shared workspace `SourcePackages` is kept,
and the accepted codec candidate retains its two Release app bundles only.
The private cleanup receipt identifies exact retained and removed paths.

## Native offline gates

Explicit arguments are `--workspace <isolated-prepared-workspace>`,
`--libro-worker <packaged-LibroSpeechWorker>` and
`--voicerelay-worker <packaged-VoiceRelaySpeechWorker>`. Use a disposable workspace
with validated existing model inventories, never the live app library. Do not copy
large build caches or implicitly acquire assets. Prepared model links can be
operator-supplied; inference may create only owned scratch/checkpoint files there.
Harness workers have an OS network denial. Missing/invalid inventories fail with
local diagnostics, not downloads. Run only while both production apps are idle:
the existing harness deliberately exercises the real cross-app admission lease.

The tier reuses the native regional frontend corpus, synthetic 12-page PDF and
600-word Markdown mixed job (both engines), host/helper footprint reports, one
worker, prepared transfer, hard memory failure fixtures, admission priority and
waiting cancellation/reaping. GPU work is serialized except for the deliberately
contending workers within the admission test; only one holds inference admission.
These measurements are not a throughput SLA or a hard whole-system allocation cap.
Listening and actual OCR/caption quality remain operator-owned.

The focused printed-word PDF experiment has an additional offline harness mode:
from `swift-packages/`, after building `NarrationNativeCheck`, invoke the built harness with `WORKER WORKSPACE OUTPUT_DIRECTORY
pdf-word-joins`. Use the same isolated workspace/idle-app rules above, once for
each packaged app helper. It generates a synthetic PDF, checks repaired text and
source maps against an independent unwrapped control through both native engines,
then renders/decodes finite nonempty WAVs at each engine's native rate. Its
`pdf-word-joins.json` is engineering evidence, not listening acceptance. Routine
`PDFWordJoiningTests` and `PDFLayoutTests` run without models in the full tier.

### Additional model checks

The explicit VoiceServer VS00 handoff probe uses an opt-in helper mode; normal
app serving is unchanged. From the repository root, build the existing products
with prepared/pinned dependencies (no model acquisition):

```sh
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' bash swift-packages/scripts/prepare-dependencies.sh
swift build --package-path swift-packages -c release --disable-sandbox --skip-update --force-resolved-versions --product NarrationSpeechWorker --jobs 4
swift build --package-path swift-packages --disable-sandbox --skip-update --force-resolved-versions --product NarrationNativeCheck --jobs 4
swift-packages/.build/debug/NarrationNativeCheck WORKER WORKSPACE NEW_OUTPUT handoff qwen3
swift-packages/.build/debug/NarrationNativeCheck WORKER WORKSPACE NEW_OUTPUT handoff kokoro firstSentence
swift-packages/.build/debug/NarrationNativeCheck WORKER WORKSPACE NEW_OUTPUT handoff qwen3 qwenIncremental
swift-packages/.build/debug/NarrationNativeCheck LIBRO_WORKER WORKSPACE NEW_OUTPUT reload qwen3 VOICERELAY_WORKER
swift-packages/.build/debug/NarrationNativeCheck WORKER WORKSPACE NEW_OUTPUT safety qwen3
```

`WORKER` must be a newly built helper supporting `--handoff-probe` (use
`swift-packages/.build/release/NarrationSpeechWorker` for Release measurements); `WORKSPACE`
is an existing isolated prepared-model workspace. `NEW_OUTPUT` must not already
exist. Select one installed model: `kokoro`, `soprano`, `qwen3`, `chatterbox` or
`orpheus`. Run serially with both apps/helpers idle and explicit native-probe
authorization. The harness denies helper networking, discards stderr, monitors
the existing per-model footprint budget and reaps only its owned process.

The helper acquires the current and legacy inference locks itself before model
load, retains model-storage protection, and holds exclusion through job join,
GPU drain and model unload, including parent EOF. Do not wrap this mode in a
host-owned InferenceLease: that would contend with its own helper. Model/voice
settings are fixed to the chosen model's default voice at 1× with seed 42. No
user preferences, private documents or live services are used.

The probe generates a control passage, cancels a new attempt 50 ms after its
first inference-start event, then regenerates in the same loaded worker. It uses
the existing semantic/prepared-phoneme paths and owned direct generation calls;
Soprano's internal token task is explicitly retained/joined by the recorded patch;
public incremental streams with hidden outer producers are not used. One outstanding PCM
frame provides backpressure; the final acknowledgement settles before ready.
Independent WAV decoding checks every delivered Float32 sample without gain.

The optional `firstSentence` mode applies the versioned live-only first-sentence
policy to the first ordinary window, preserving source/pronunciation mappings and
indivisible overrides. Normal app/podcast segmentation is unchanged. The
`qwenIncremental` mode additionally uses the recorded synchronous throwing Qwen
callback, on the owned producer task, with a 0.5-second decoder interval. It
checks codec-token/sample coverage, records direct-versus-streaming PCM diagnostics,
cancels with the first frame unacknowledged, then compares regenerated incremental
PCM after decoder reset. Either PCM parity failure produces a nonzero gate exit
and a retained failed receipt after lifecycle/reuse checks finish; valid containers,
sample counts and fast cancellation cannot make that gate green. The 0.001 maximum
absolute-difference threshold is a conservative numerical-review check, not a
listening standard. Silent incremental frames are retained. Both modes also
record an ordinary paragraph baseline in the same loaded worker; this is a
sequential local comparison, not a randomized performance benchmark. The ordinary
baseline includes first-use kernel/preparation costs; do not infer a speedup ratio
from its comparison with later warm requests.

The `reload` command uses two newly built packaged helpers and one installed
VoiceRelay-supported model (`soprano` is Libro-only). It observes the new helper
waiting on the actual current/legacy locks while Libro retains weights, cancels
and joins Libro, closes its input, observes model unload, then observes VoiceRelay
acquire the lease and load. The receipt includes acceptance-to-first-WAV across
helper spawn, lease wait, unload, model load and generation. This driver sequences
the transfer; it does not implement the production priority scheduler. Private
probe wire version 4 adds responsive initialization cancellation/EOF and terminal
`initializationCancelled` acknowledgements; normal SpeechIPC remains version 3.

The `safety` command first checks cancellation and EOF while waiting on the actual
compatibility locks, at load entry and at the controlled loaded-weight/pre-admission
barrier, then EOF from loaded idle. Entry cancellation can precede allocation;
the explicit loaded barrier requires real model references and unload before the
terminal acknowledgement. Each owned
helper must settle/reap and release exclusion before the next case. Waiting tests
deliberately hold a host lease as a blocker without loading a model; other phases
leave the locks to the helper. The final helper performs nine cancel/reuse cycles
(three each before start, at inference start and after a stalled first frame), ten
completed short synthetic requests and supported per-job voice/speed changes with
default-setting restoration. It records ready/peak footprints, not a claim of
long-duration stability. Soprano uses Libro's helper and remains Libro-only.

Initialization is an owned task joined before reset/unload, rather than blocking
the control reader. A cancelled/failed load is terminal for that helper and never
reports job-ready; compatible demand transfer is still coordinator integration
work. Concurrent close callers share one bounded exit-handler/reap outcome.
The decoder CPU regression can be run directly with
`WORKER --qwen-decoder-probe`; it uses fixed synthetic weights and requires no model.

`receipt.json` records worker/hash/model identity, initialization time, warm
request-to-first-playable-WAV time, cancellation-to-ready time, bounded-frame
trace and sampled peak footprint. Seeded control/resumed hash equality is
informational; stochastic regeneration need not be identical. First playable WAV
is a local unit-publication metric, separate from HTTP/server TTFA and client
playback. Changed selections, reference voices, longer memory stability and
listening remain separate evidence. Probe deadlines
are not production cancellation or latency policy. The
[VoiceServer checklist](VOICESERVER_IMPLEMENTATION_CHECKLIST.md) records results.

The model-free regression seam is included in ordinary fixtures. Its focused
selection is `LiveSpeechFirstUnitTests|SpeechHandoffProbeTests|VoiceServerProofTests|SpeechWorkAdmissionTests|SpeechAttemptFenceTests|SpeechHostAdmissionTests|SpeechWorkCoordinatorTests|SpeechRenderJournalTests|LibroBatchRecoveryTests|SpeechCPUWorkTests|SpeechWorkWakeupTests|SpeechWorkStatusTests|AudioStreamEncoderTests|PronunciationUITests.testPreviewKeepsTheCapturedAppWorkerOwner|deletionRunsInsideOwnedMaintenanceAndFailurePreservesAssets` under the existing
quick/shared scope.
VoiceRelay's `CoordinatedCheckpointTests` under quick/voicerelay adds actual private
SQLite commit/rollback, pending-validation retry, writer contention and Stop/API
isolation. Both suites use temporary owned state and fake speech workers. The full
gate discovers these tests automatically; no live library/model/HTTP access occurs.
Host/app ownership regressions also run under quick/voicerelay with filter
`detachedArticlePreparationPreservesRankedHostContext|coordinatedAppQuitJoinsPlatformLeaseAndClosesWorkerOwner`.
They use a fake title generator and isolated kernel locks, never Vision,
Foundation Models, local speech recognition or protected input.

The opt-in coordinator/render adapter has a separate installed-assets-only check.
With both apps/helpers idle, an already prepared workspace, a newly built packaged
worker and a **fresh, nonexistent** output directory, run from the repository root:

```sh
swift-packages/.build/debug/NarrationNativeCheck \
  /path/to/Libro.app/Contents/Helpers/LibroSpeechWorker \
  /path/to/prepared-workspace /path/to/new-coordinator-evidence coordinator kokoro
```

Use the helper's actual packaged path as reported by the bundle audit; the example
path is illustrative. This mode denies helper networking, uses isolated demand
metadata and retains the global compatibility locks. It checks prepared text,
bounded generation, same-helper API reuse, resume and owned reap; it records worker
SHA/revision and private WAV/JSON receipts. It also exercises the native session's
deferred checkpoint result: cursor stays unchanged until exact Float32 WAV readback
and receipt commit. The current mode also exports `api-stream.mp3` and raw
`api-stream.pcm` using each response's persistent encoder, records bytes emitted
before flush and fingerprints the packaged codec. Compare the MP3 with `api.wav`
for the operator listening check; raw PCM is mono signed 16-bit little-endian at
24 kHz with no header. Synthetic codec fixtures independently decode an unfinished
MP3 prefix, compare arbitrary frame segmentation and verify exact PCM bytes and
resampler continuity. These are not HTTP first-audio timing measurements.
The private coordinated/probe wire is now version 6; older helpers are rejected
before initialization. Normal serving IPC remains version 3.
It does not exercise a listener, change
app defaults, download assets or establish listening/long-duration acceptance.
Run models serially and retain the receipt even on failure.

The default native tier above retains its Kokoro/Soprano corpus. It does not
implicitly run the much larger model matrix. After building the shared harness,
these explicit commands run from the repository root with the same isolated
prepared workspace and idle-app requirements:

```sh
swift-packages/.build/debug/NarrationNativeCheck WORKER WORKSPACE OUTPUT models
swift-packages/.build/debug/NarrationNativeCheck WORKER WORKSPACE OUTPUT models languages
swift-packages/.build/debug/NarrationNativeCheck WORKER WORKSPACE OUTPUT models longform
swift-packages/.build/debug/NarrationNativeCheck LIBRO_WORKER WORKSPACE OUTPUT contention VOICERELAY_WORKER large
```

Replace the uppercase placeholders with absolute paths and use a fresh output
directory per command. `models` checks all 18 new presets; an optional `qwen3`,
`chatterbox` or `orpheus` narrows it to one family. `languages` uses authored
phrases for all ten Qwen languages. `longform` generates multi-paragraph synthetic
prose with Ryan, Chatterbox default and leah, exercising repeated reload/assembly.
The `large` contention check uses interactive Qwen and background Orpheus through
the two helpers; it verifies priority, non-overlapping process lifetimes and
waiting cancellation. Receipts include helper hashes and prepared plans.
Use `models longform-orpheus` (or another family ID after `longform-`) for a
focused repeated-utterance check while diagnosing a model-specific failure.

For the synthetic reference check, first run `models chatterbox` with its output
named `native-voices-chatterbox`, then run `models reference` with a sibling output
directory. It imports that generated WAV into an isolated profile store, never
the user's reference store. No command downloads models or launches either GUI.
These checks establish mechanical generation, not linguistic or listening quality.

## Xcode and release evidence

Existing LibroCoreTests and app schemes have explicit Test actions targeting real
XCTest bundles. Do not use generated dependency schemes as test entry points:
their existence does not imply a working Test action. SwiftPM is the canonical
full-fixture harness, including VoiceRelay app tests not present in its Xcode test
target. Build Both Apps is build-only, never Test/Archive.

Release uses command-line ad-hoc overrides only; normal project/team/Keychain
settings are unchanged. These ad-hoc overrides clear the team and configured
Keychain entitlements: they are suitable for isolated fixture/GUI checks, but
cannot exercise VoiceRelay's protected password store, saved-credential Test
Connection or background Publishing. For those checks, the operator builds/runs
the normal VoiceRelay scheme with its usual team, provisioning profile and
`Packaging/VoiceRelay.entitlements`, with no ad-hoc overrides. Command-line builds
can use the same signing configuration; the signing mode, rather than whether
Xcode's GUI was used, determines capability. Do not delete saved credentials,
weaken the Keychain policy or add a file-based fallback for an engineering build.
Artifacts stay under ignored workspace DerivedData and
the run's own Archives. Each generated bundle is verified for arm64, private
worker, helper-only MLX, Metal execution, notices/sample fingerprints, Libro's
codec and deep/strict signatures. Full fixtures cover encoding behavior; packaging
does not by itself verify acoustics. Human signing, notarization, clean-Mac,
installer/player and services remain in [operator validation](OPERATOR_VALIDATION.md).

## Development versioning

`Version.xcconfig` owns each app's marketing milestone (`LIBRO_MARKETING_VERSION`,
`VOICERELAY_MARKETING_VERSION`); milestone entries are recorded in the root
`CHANGELOG.md`. The build number is never authored: the first build phase runs
`scripts/generate-app-info.sh`, which requires a full-history Git work tree
(non-shallow, committed HEAD) and stamps `CFBundleVersion` with
`git rev-list --count HEAD`, `NarrationAppsGitRevision` with the full revision
and `NarrationAppsSourceModified` with the worktree flag into a generated
Info.plist under `DERIVED_FILE_DIR`. The build number advances per commit on
normal history; branch counts are not globally unique, so the full revision is
the identity. Bump the marketing minor for meaningful features and the patch
for fixes; record milestones in the changelog; create tags only when explicitly
requested. `bash scripts/test-app-versioning.sh` exercises the generator
against a synthetic repository. Each GUI target's phase declares recursive
sandbox inputs for `.git` plus every tracked immediate child of its SRCROOT;
adding a new top-level maintained file or folder under an app SRCROOT requires
a matching phase input, enforced by `scripts/check-layout.swift`.

## Tooling regressions

`bash scripts/test-development.sh` uses native Swift, fake runners and tiny
Git repositories under ignored `.local/`. It checks malformed manifests,
missing/untracked app sources, nested repositories, dirty-root strict mode, symbolic
links, unsupported tools, setup preservation, selection and failure evidence.
It does not contact remotes or use the archival source trees.

## Scoped formatting and document ownership

Use the installed `swift format`, with the identical explicit
`.devin/swift-format.json` in each formatting scope. Four spaces, a 120-column target,
stable multiline strings/import ordering and no automatic privacy rewriting keep
the rules modest. There is no formatter package dependency.

`bash scripts/format.sh lint all` strictly checks only each owner's
`.devin/format-files.txt`; `apply` is the explicit fixing mode. Choose `root`,
`Libro` or `VoiceRelay` instead of `all` for one source scope. Initial enforcement
covers the native tooling plus one small extracted file per app, not a wholesale
legacy reformat. Graduate additional maintained files in formatting-only commits
after behavior changes are committed and reviewed. The script rejects generated,
patch/notice/golden-fixture paths and compares all three configurations.

The current guides and historical records are indexed by [docs/README.md](README.md).
[Documentation policy](DOCUMENTATION.md) defines audience/ownership and checks for
nested guides outside the standard documentation scopes. App validation pages link
to current shared results rather than maintaining rival totals. Historical stage
counts/provenance remain historical, not today's acceptance. Ignored raw reports
are optional local evidence; setup and current guides must work without them.

### Shared Hugging Face cache check

The ordinary fixtures use temporary synthetic caches and never alter the user's
cache. The opt-in `ModelStorageTests/testOfflineSharedCacheInstallationAndGeneration`
seeds a temporary standard Hub cache from explicitly supplied, already validated
local assets, installs offline, generates one synthetic passage, verifies shared
snapshot hashes and tests in-use deletion protection. It deletes only that temporary
cache. It honors shared background inference admission; run it apart from builds
and timing benchmarks. From the repository root, after building the worker:

```sh
NARRATION_CACHE_SOURCE="$PWD/.local/tts-model-benchmark" \
NARRATION_CACHE_WORKER="$PWD/swift-packages/.build/debug/NarrationSpeechWorker" \
NARRATION_CACHE_MODEL=kokoro \
swift test --package-path swift-packages --disable-sandbox --skip-update \
  --force-resolved-versions --jobs 4 --no-parallel \
  --filter 'ModelStorageTests/testOfflineSharedCacheInstallationAndGeneration'
```

Use an explicitly prepared workspace for the source; the example private directory
is not a fresh-clone prerequisite. Supported selections include `kokoro`, `qwen3`,
`chatterbox` and `orpheus`. Without both source and worker environment variables,
the native case is reported as skipped. Ordinary model-storage tests stay model-free.
