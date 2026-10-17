# Development gates

Start with [contributor setup](../CONTRIBUTING.md). Run from NarrationApps.
Tests use synthetic isolated inputs; no GUI is launched. Setup is the only
network-acquisition entry point. Prepare sources before running gates; no test
runner installs models. Tests/builds run serially at the tier level, with four
compiler jobs. Do not overlap timing-sensitive tests and heavyweight builds.
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
| `bash scripts/check.sh --tier quick --scope voicerelay --filter appModel` | Also matching VoiceRelay tests |
| `bash scripts/check.sh` | Full isolated AppPresentation/shared/LibroCore/VoiceRelay core+app suites, preparation, number, packaging and static regressions |
| `bash scripts/check.sh --tier native` | Unavailable (exit 3) until explicit prepared-model/worker arguments are supplied |
| `bash scripts/check.sh --tier release --adhoc` | Workspace Debug/Release builds, each app's individual Archive, bundle/resource/signature/Metal checks |

Scope/filter is quick-only. Filters are Swift test regular expressions. No matches
is a failure; a selected pass is never a full pass. Fixture worker and prepared
codec environment are supplied to affected shared/app suites.
Full retains the existing package/app scripts as owners and runs shared tests once.
Existing explicitly opt-in acoustic tests remain reported skips, not acoustic passes.
Inherited private review/native opt-ins are removed by the tier runner.

Every run creates `.local/validation/<tier>-<id>/summary.json`: actual three source
revisions/dirty state, actual toolchain/SDK/architecture, selection, step kind,
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
independent Git repositories in an owned disposable sibling. It checks malformed
manifests, missing/unavailable revisions, deliberate divergence, unsupported tool
selection, repeat setup preservation, arguments, selection and failure evidence.
It does not contact remotes or use the archival source trees.
