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
settings are unchanged. Artifacts stay under ignored workspace DerivedData and
the run's own Archives. Each generated bundle is verified for arm64, private
worker, helper-only MLX, Metal execution, notices/sample fingerprints, Libro's
codec and deep/strict signatures. Full fixtures cover encoding behavior; packaging
does not by itself verify acoustics. Human signing, notarization, clean-Mac,
installer/player and services remain in [operator validation](OPERATOR_VALIDATION.md).

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
