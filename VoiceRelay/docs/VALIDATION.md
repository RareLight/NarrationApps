# Validation evidence

Updated October 3, 2026. The deliverable is now `/path/to/VoiceRelay`.
Build/test evidence from before relocation is retained below as historical evidence;
it does not establish a successful build of the new Xcode project. No deferred
production functionality is certified.

## October 3 operator-confirmed Kokoro fixture

After rebuilding/retrying, the operator reports that Kokoro worked as expected.
The operator also reports **Metal API Validation was already unchecked**. This
is successful operator speech-fixture evidence; it does not establish that changing
that setting caused the recovery. The preceding crash reports remain valid, but
the precise trigger and reason for recovery remain unresolved. The agent did not
execute actual MLX inference or GUI/listening checks. Detailed listening, interrupted
recovery, long-input memory and final-agent acceptance still require separate evidence.

The operator now requests removal of the user-facing mock mode and continued
development. Settings must ultimately be editable in the app, with sensible
defaults, a few relevant choices, and application-managed opaque storage. TOML
files and manual pipeline parameters are not the intended product configuration
experience. Historical imports/data must remain untouched.

## October 3 GUI speech crash diagnosis and targeted workaround

The operator's screenshot shows Kokoro speech selected and `Speech helper exited
or closed its control connection`; no local episode/feed was generated. Read-only
inspection found three macOS Python crash reports at 10:25, 10:26 and 10:28 local
time. They identify VoiceRelayApp as parent/responsible process and show SIGABRT
(6) through `mlx::core::Gather::eval_gpu`, Metal's debug compute encoder `setBytes`,
`MTLReportFailure`, assertion and abort, on macOS 27.2 build 26B5091g. Those reports
establish an actual native helper crash in MLX/Metal. They do not contain the exact
assertion message or identify the failing narration chunk.

The stack closely matches [upstream MLX issue #4061](https://github.com/ml-explore/mlx/issues/4061),
an empty-vector Metal binding failure exposed by API Validation. That specific
mechanism remains inferred. The pinned dependency/model selection remains intact.
The shared VoiceRelay Run scheme now explicitly disables Metal API Validation as
a development workaround; inference with that setting remains an operator gate.
The generic process supervisor now reports startup/preparation/synthesis and the
exit status or signal, with a bounded termination-notification wait, without
exposing helper logs, narration or filesystem paths. Cancellation/deadline and
owned-process cleanup still apply.

| Check | Result and scope |
| --- | --- |
| Provider startup only | The actual project-owned Python interpreter ran `-I -B runtime/kokoro/provider.py` with stdin EOF: exit 0, one protocol-v1 hello, no stderr. No prepare/synthesize request, MLX import, model load or inference was performed. |
| Scheme / project metadata | Shared scheme XML parses and explicitly has `LaunchAction enableGPUValidationMode="1"` (disabled). Xcode project and app plist pass `plutil -lint`. Xcode GUI interpretation remains an operator check. |
| Focused native build/tests | `CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" swift test --cache-path "$PWD/.build/swiftpm-cache" --disable-sandbox --skip-update --filter 'speechHelper\|kokoroMissingRuntime'`: **8 Swift Testing tests passed** (21 individual cases; no skips). Debug shared core, app, CLI and tests compiled. Five new cases verify startup/preparation/synthesis exit codes, signal termination and a still-running helper that closes stdout, with bounded cleanup and no request text/path in errors. Existing reuse, numeric speed, unsafe outputs, cancellation/deadlines/owned descendants, missing runtime/confinement and synthetic SQLite→M4A/RSS checks passed. User-cache/deprecated-option warnings remain; no Swift source diagnostic. Log: ignored `var/validation/2026-10-03-speech-crash/swift-focused.log`. This is synthetic protocol/pipeline evidence, not actual MLX inference. |
| Preservation | No provider, runtime setup, dependency/model pin, Python reference, customized configuration, saved fixture/published data, cache/download policy or service enrollment change. `.runtime/`, `models/` and generated `var/` remain ignored. |
| Outstanding acceptance | Actual GUI/CLI Kokoro completion, M4A listening, repeat/recovery, Canvas and full native/Release gates remain open. No change to linkd/Intents or status-item layout warnings is claimed. |

See the [step-by-step Xcode retry](KOKORO_PROVIDER.md#speech-helper-aborts-under-xcode-metal-api-validation).

## October 3 source-quality and whole-number speech-speed corrections

The operator reported duplicated captions, images in cleaned HTML, apparent
apostrophe/quote mojibake in two private exports, footnote markers in narration,
and `Speech speed must be a number` during CLI speech generation. The operator
also reports fixture steps worked until CLI generation, with tones heard in mock
mode. This does not establish Kokoro speech completion/listening acceptance.

Read-only inspection of the two supplied snapshots found UTF-8 source/cleaned/JSON
bytes with correct Unicode and no literal `â€™` sequences. Both original sources
declare UTF-8; cleaned fragments had no charset metadata. The reported display is
consistent with interpreting UTF-8 through a legacy charset, rather than evidence
of damaged stored text. Browser rendering was not inspected by the agent. The
headlight source DOM contains two copies of its caption, including lightbox
markup; both survived into the old cleaned HTML and JSON. The existing narration
normalizer had not removed that duplicate. The blog export retained five linked
footnote references and their definitions.

The speech failure was localized to numeric checkpoint decoding: `.number(1.0)`
encodes as JSON `1`, which `SettingValue` decodes as `.integer(1)`. The helper's
speed guard accepted only `.number`. Numeric settings now accept either form,
without accepting strings/booleans or relaxing speed bounds. GUI/CLI profile
selection uses the same numeric interpretation. The Settings mode picker now
shows both Mock tones and Kokoro speech in a segmented control.

Cleaned exports now declare UTF-8, remove inline media, preserve caption semantics
and deduplicate adjacent equal captions. Semantic blocks retain marker text plus
optional spoken-text/reference/definition fields. Narration resolves marked local
footnotes/citations once after the first referring block, with Footnote/End
Footnote cues, retaining multi-paragraph note bodies and source-block provenance.
Unresolved marked references produce notices; ordinary numbers/superscripts and
unmarked citations are preserved. Referenced definitions removed by Readability
can be recovered from the original source; unrelated source notes are not added.
Decorative symbol separators are omitted from speech. Version fingerprints changed;
valid published checkpoints retain their saved versions/artifacts, while unfinished
work still validates current versions/fingerprints.

| Check | Result and scope |
| --- | --- |
| Focused native build/tests | `swift test` with project-local caches, `--disable-sandbox --skip-update`, filter `SourceReviewTests\|sourceExtraction\|semanticBlocks\|narrationHas\|speechHelper`, and explicit `VOICERELAY_REVIEW_FIXTURES`/`VOICERELAY_REVIEW_OUTPUT`: **28 Swift Testing tests passed, no skips**. Debug shared core, app, CLI and tests compiled. Tests include UTF-8/full HTML, media removal, adjacent-caption-only deduplication, number/star/dagger/citation markers, multi-paragraph notes, backlinks, ordinary numbers/superscripts, unresolved notes, discarded appendix recovery, older optional-field decoding, numeric speed JSON round trips, invalid speeds and existing helper cancellation/provenance checks. Full native suite and Release were not run. |
| Private saved-source regression | Both explicitly selected snapshots were reprocessed offline, with no fetch. Refreshed exports are in the project's ignored `var/article_snapshot_fixed/` under new UUIDs. Both have UTF-8 metadata, zero inline images and no literal mojibake apostrophes. The headlight caption occurs once in cleaned HTML and narration (five retained captions total; 60 chunks). The blog export has five Footnote and five End Footnote cues (68 chunks); the cited third note has two paragraphs, its referring marker is omitted from speech, and no backlink arrows are spoken. Original source bytes/mtime stayed unchanged; old exports were not rewritten. Rendering/listening/completeness remain separate gates. |
| Persisted speed / encoder integration | An owned synthetic protocol helper ran through actual native SQLite checkpoint serialization, ffmpeg/ffprobe M4A/RSS publication with speed 1.0, and an idempotent repeat. This is process/pipeline evidence, not real Kokoro speech. |
| Published-version compatibility / recovery | After the last coordinator compatibility change, focused filter `speechHelperNumericSpeedSurvivesPersistedFixture\|speechFingerprintChangesInvalidateUnpublishedAudio\|speechCompatibleCheckpointResumesAndLegacyEpisodeDecodes`: **3 tests passed**, including two fingerprint boundary cases. Published older-version checkpoint/article/narration, M4A and RSS bytes remain unchanged with zero synthesis; unpublished changed-backend work invalidates/rebuilds as required; compatible interruption reuses completed chunks and older episode JSON decodes. Debug app/core/CLI/tests rebuilt. One test overlaps the 28-test run above. |
| Project / preservation | App plist and Xcode project pass `plutil -lint`. No new dependency, pin, runtime/model download, Python-reference/configuration/live feed/audio change or service enrollment. New private exports remain under ignored `var/`. Future local image descriptions are recorded in the plan only. |
| Operator gates | Xcode GUI/segmented-picker and Canvas rendering, browser display of the corrected HTML, source completeness, actual Kokoro CLI/GUI inference and listening remain **unverified by the agent**. Selected network articles still have review/export only; their speech pipeline and durable queue remain pending. Startup layout/linkd warnings are unchanged. |

See the [updated speech instructions](KOKORO_PROVIDER.md#first-user-run-speech-check-in-xcode)
and [caption/footnote policy](SOURCE_REVIEW.md#caption-encoding-and-footnote-policy).
Use a fresh empty speech fixture directory when testing the new build. Actual
MLX/Metal model execution is handed to the operator; the agent's checks use only
synthetic helpers and isolated generated audio.

## October 3 runtime readiness and manual source-review development

Subsequent operator GUI evidence: Reading List articles appeared after selecting
`Bookmarks.plist` through **Choose plist…** and refreshing. The operator reports
that articles did not appear by default. This confirms selected-file discovery
and list presentation under that run's app context. It does not establish
default-path access, access persistence after relaunch, inventory completeness,
source extraction quality or speech acceptance. Opening Articles deliberately
does not refresh; no pre-selection refresh error/path was supplied, so no specific
permission or default-path cause is diagnosed. No source change or new build/test
was performed for this operator-evidence update.

The operator reports that Kokoro setup is now good. The agent subsequently ran
`PYTHONDONTWRITEBYTECODE=1 python3 runtime/kokoro/runtime_setup.py check`:
exit 0 and `ready: true` for `mlx-community/Kokoro-82M-bf16`, revision
`a71e4d38b236d968966a2002c4c895dbd12b1c3c`, in the project's model directory.
This is installed package/asset/provenance readiness evidence; no inference,
Metal allocation, audio generation or listening was performed. It supersedes
the setup-unavailable states recorded below for earlier revisions.

Implemented the first part of Slice 3: shared XML/binary read-only Reading List
parsing and session inventory; one selected bounded ephemeral URLSession fetch;
plain-text semantic/narration review; conservative page inspection outcomes;
explicit private UUID snapshot export; Articles window, inert previews and
diagnostic CLI commands. Exclusions/inventory are session-only. There is no new
durable queue, real-article speech pipeline or live state adoption. The shared
core remains used by both build routes; Xcode source references include the new
view and focused test file.

| Check | Result and scope |
| --- | --- |
| Focused native suite / Debug compilation | `CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" swift test --cache-path "$PWD/.build/swiftpm-cache" --disable-sandbox --skip-update --filter SourceReviewTests`: **13 Swift Testing tests passed**, including parameterized XML/binary, eight response failures, four page inspection outcomes and two cancellation/deadline cases. SwiftPM Debug shared core, app, CLI and test sources compiled. The full existing native suite and Release were not rerun. |
| Discovery fixtures | Synthetic XML/binary nesting, UUID deduplication, distinct UUIDs at the same URL, date/fallback identity, unsafe URL skipping, malformed/deep/oversized refusal, unchanged source bytes/mtime, successful merge and retained absent/excluded entries after a failed read. No actual Safari file opened. |
| Fetch policy and transport fixtures | In-process URLProtocol responses test HTML bytes/provenance, no cache/cookie/credential stores, status/type/empty/encoding/known-length/streamed-size/transport-policy errors and safe diagnostics. Deadline and cancellation pass both before headers and after a partial body; no external socket/network source. Redirect delegate checks exercise per-hop downgrade/credential/limit refusal and header stripping; they do not validate actual live redirect/auth/TLS delivery. |
| Review and private export | Saved synthetic article preserves original/final/canonical provenance and ordered narration. Title heuristics/empty extraction produce inspectable outcomes. Exports preserve raw source bytes/hash, opaque UUIDs, owner markers and 0700/0600 modes; refuse unowned nonempty, symlinked-owner, configured overlap, selected fixture overlap and marked fixture ancestor destinations. Flagged export has no fabricated article. |
| CLI smoke | Built Debug CLI reads checked-in `Fixtures/reading-list.synthetic.plist`: two entries, zero skipped, no source URLs/titles printed, unchanged bytes/mtime. A `file:` review URL returns exit 1 with a fixed diagnostic before creating any destination. CLI smoke uses an isolated temporary working directory. |
| Xcode source/config static checks | `plutil -lint` passes for project, app plist and synthetic plist. Parsed project verifies new app/test compile-phase membership and shared core references, with all compile inputs present. SwiftPM/Xcode dependency pin arrays still match. Installed `xcodebuild -version`: Xcode 27.2, build 27B5028f. No new Xcode bundle build/test or GUI run is claimed; prior manifest/cache restriction is recorded below. |
| Runtime/model and preservation | Readiness check only; no setup or downloads. Existing `.gitignore` retains project-local model/runtime/cache ignores, and `var/` covers suggested review exports. Historical Python, benchmark environment, customized TOML, live database/feed/audio, dependency pins and service registration were not changed. |
| GUI / protected sources / speech / live acceptance | **Not run by the agent.** Xcode bundle/test/Canvas, window interactions, actual Safari hierarchy and app-identity permission, live redirect/auth/ATS behavior, representative short/medium/long source completeness, real Kokoro inference/listening, signed relocation, agent context and delivery remain gates. |

Only existing deprecated `--skip-update` and unavailable user-cache warnings
were emitted by the final SwiftPM check; no Swift source diagnostic remained.
System ATS protections remain enabled; some HTTP sources can be refused even
though HTTP(S) URLs pass the source validator. This limitation is explicit in
the [source-review guide](SOURCE_REVIEW.md), alongside operator-owned checks.
Conservative login/consent/access-title heuristics are not a comprehensive source
classifier. The layout/linkd investigation is unchanged and remains separately
documented; successful compilation does not certify its resolution.

Next operator actions: follow [the step-by-step Xcode source-review checks](SOURCE_REVIEW.md#step-by-step-xcode-checks)
and the independent [Kokoro speech/listening guide](KOKORO_PROVIDER.md#first-user-run-speech-check-in-xcode).
Full Slice 3 completion still requires durable queue/retry implementation and
reviewed-article speech/source-quality evidence. Nothing enrolls a service,
publishes remotely, changes hosting or consumes the Reading List backlog.

## October 3 source-only docopt installation correction

Historical setup-fix evidence. The readiness/setup confirmation above supersedes
this section's then-open installation gates; its original results are preserved.

The operator's latest retry used the already installed Python 3.12.15 and created
`.runtime/kokoro/.venv` successfully. The pinned package stage then stopped because
`docopt==0.6.2` has no usable wheel while setup imposed `--only-binary :all:`.
This supersedes the earlier missing-venv state below; it does not certify the
dependency or model installation.

The lock includes docopt through num2words. PyPI's release metadata lists only
the 25,901-byte source archive, with SHA-256
`49b3a825280bd66b3aa83585ef59c4a8c82f2c8a522dbe754a8bc8d08c85c491`, matching
the existing application lock. Read-only inspection of the corresponding benchmark
lock identifies docopt as the only application-pinned package with no listed
wheels; this does not establish every other wheel's platform compatibility or
availability during an actual clean setup.

Setup now retains `--only-binary :all:` and adds the specific `--no-binary docopt`
exception. It retains `--require-hashes` and supplies the existing hashed lock as
`--build-constraints`, including its setuptools pin, for isolated build dependencies.
No requirements hash, version, global configuration, Swift source, Python reference,
benchmark runtime or live/published data was changed. All build/cache/venv paths
remain project-owned and ignored by the existing `.gitignore`.

| Check | Result and scope |
| --- | --- |
| Offline setup suite | `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s runtime/kokoro/tests -v`: **14 tests passed**, no skips. The production command assertions include the docopt-only exception, hashed requirements, owned interpreter and explicit build constraints. |
| Actual uv source-policy regression | uv 0.11.7 with the already installed managed Python ran against local synthetic source archives, `--offline` and `--no-index`, in separate temporary project-owned venvs/caches. Four cases passed: the old blanket policy refuses the synthetic docopt sdist; the exception builds/installs it and its module/version import succeeds; an unrelated source-only package is still refused; a wrong source hash is rejected. The synthetic backend uses only stdlib and requires no build dependencies. This is policy evidence, not an upstream docopt/setuptools build or real TTS acceptance. All temporary source-policy fixtures were removed. |
| Dependency provenance / scope | Published docopt archive hash matches the existing lock; the inspected benchmark lock lists no wheel for docopt and lists wheels for the other matched pins. No runtime/model/dependency download was performed by the agent. |
| Python source parse | Setup, provider and setup test sources passed `ast.parse` without writing bytecode. |
| Full setup / native / GUI / speech | Full package/model installation, actual upstream docopt build, runtime check, Metal inference and listening remain operator gates. Native builds, GUI and Canvas were not rerun for this Python setup-only change; prior native evidence remains historical. |

Next operator action: rerun `python3 runtime/kokoro/runtime_setup.py setup --download`
from the project root without deleting the interpreter or venv, then run
`python3 runtime/kokoro/runtime_setup.py check` after setup succeeds.
See [the provider guide](KOKORO_PROVIDER.md#storage-and-explicit-setup).

## October 2 managed-Python option conflict correction

The operator's retry successfully installed project-owned CPython 3.12.15, then
failed during virtual environment creation with `--managed-python` cannot be
used with `--python-preference`. The script itself supplied both the CLI flag
and `UV_PYTHON_PREFERENCE=only-managed` in its child environment; this was a setup
bug, not evidence of an incompatible Python download or changed global settings.

The duplicate environment preference has been removed. The explicit managed-only
venv flag, exact Python version, disabled venv downloads, owned install/cache
paths, and explicit venv Python target for package synchronization remain in place.
Inherited uv preferences continue to be stripped. No Swift source, package/model
pin, global configuration, Python reference or published data changed.

| Check | Result and scope |
| --- | --- |
| Actual failure reproduction | uv 0.11.7 returned exit 2 with the same option-conflict error using the old setup environment and `--offline` against an isolated temporary venv target. No download or package installation occurred. |
| Offline setup regression suite | `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s runtime/kokoro/tests -v`: **13 tests passed**, no skips. The new regression uses the actual setup environment, installed uv and already downloaded project-owned Python to create a temporary venv under `.runtime/tmp`, verifies its interpreter resolves to `.runtime/python/cpython-3.12.15-macos-aarch64-none/bin/python3.12`, runs that interpreter with `-I -B`, and confirms version 3.12.15 and the temporary venv prefix. The fixture was removed afterward. No network, MLX, model or dependency installation. |
| Operator installation evidence | Supplied console confirms successful CPython 3.12.15 installation before venv creation failed. The temporary regression also verifies that installed interpreter runs; it does not complete `.runtime/kokoro/.venv` or the pinned dependency/model installation. |
| Native build / GUI / speech | Not rerun for this Python setup-only correction. Prior native build evidence remains historical; full setup, runtime check, Metal inference, listening and Xcode/GUI gates remain open. |

Next operator action: rerun `python3 runtime/kokoro/runtime_setup.py setup --download`
from the project root, retaining the already installed interpreter, then run
`python3 runtime/kokoro/runtime_setup.py check` after setup succeeds.

## October 2 pinned Python download catalog correction

The operator's explicit setup stopped with `No download found for request:
cpython-3.12.15-macos-aarch64-none`, followed by the generic `CalledProcessError`.
The inspected tool is uv `0.11.7` (`9d177269e`, April 15, 2026). Its embedded
catalog lists CPython 3.12.13 for this platform and returns no download for the
selected exact 3.12.15 pin. This local reproduction identifies a catalog mismatch;
it is not evidence that the Python release or MLX packages are unavailable.

The project now supplies a single-entry `runtime/kokoro/python-downloads.json`
to interpreter installation. The published Apple Silicon CPython 3.12.15 archive
URL and SHA-256 were read from the upstream python-build-standalone `20261001`
release asset listing. The script checks the catalog's selected version/platform,
release URL and checksum format before creating runtime directories. It keeps
`--no-config`, project-owned install/cache paths and `--no-bin`; subsequent venv
creation requires the managed interpreter and disables automatic Python downloads.
Failures now report the stage and exit status/timeout without echoing the command.
The Swift backend fingerprint includes the catalog. No package/model/version pin
was relaxed, global tool updated, or Python/Conda configuration changed.

| Check | Result and scope |
| --- | --- |
| Installed uv catalog comparison | Offline `uv python list 3.12.15 --only-downloads --show-urls --output-format json` returned `[]` with the bundled catalog, then exactly `cpython-3.12.15-macos-aarch64-none` with `--python-downloads-json-url` pointing to the local catalog. No interpreter/archive was downloaded. uv routes this release URL through its official `releases.astral.sh` mirror. |
| Offline Python regression suite | `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s runtime/kokoro/tests -v`: **12 tests passed**. Includes the real installed uv's offline catalog parsing, mocked explicit setup command/environment isolation, incompatible metadata refusal before runtime creation, and stage/timeout diagnostics. No MLX imports or downloads. |
| Focused Swift check / Debug compilation | `CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" swift test --cache-path "$PWD/.build/swiftpm-cache" --disable-sandbox --skip-update --filter kokoro`: **one Swift Testing test passed**; Debug shared core, app, CLI and tests built. The test includes catalog fingerprint changes, missing-runtime refusal and escaped-model rejection. User-cache access/deprecated-option warnings remain; no Swift source diagnostic was emitted. |
| Python source parse | `ast.parse` passed for setup, provider and setup tests without writing bytecode. |
| Actual runtime / speech | **Not run.** The project-owned inference interpreter and selected model snapshot remain absent. Archive-byte checksum verification, wheel installation, G2P completeness, Metal inference, listening and Xcode/GUI acceptance remain operator gates. The catalog check does not establish full setup success. |

Next operator action: rerun `python3 runtime/kokoro/runtime_setup.py setup --download`
from the project root, then run `python3 runtime/kokoro/runtime_setup.py check` after
setup succeeds. Existing directories from the failed attempt can remain in place.
See [the provider guide](KOKORO_PROVIDER.md#storage-and-explicit-setup).

## October 2 selected Kokoro development slice

The supplied completed benchmark handoff now selects Kokoro through mlx-audio
Python. [KOKORO_PROVIDER.md](KOKORO_PROVIDER.md) records selection evidence,
project-local storage, protocol/recovery boundaries, and exact operator checks.
This supersedes older engine-selection deferrals below. Historical build/runtime
records remain evidence for their original versions only.

Implemented: public runtime/model/package pins and a hashed standalone lock;
explicit owned setup; project-local interpreter/venv/G2P/model/cache paths;
offline normal use; a serialized supervised protocol-1 `TTSBackend`; explicit
speech CLI and Settings controls; separate tone/speech ownership markers;
chunk and encoded-input fingerprints; older optional-field decoding; named inert
speech preview. The historical Python application, benchmark sources/runtime,
customized configuration, live state/media/feeds, Safari and hosting were not
modified or adopted. No service was enrolled or feed uploaded.

| Check | Result and scope |
| --- | --- |
| Dependency lock export | Offline frozen uv export from the selected benchmark graph succeeded, with the benchmark package/dev/other-engine extras excluded. App setup uses the standalone hashed result, not the benchmark environment. No interpreter/package/model download was performed. |
| Shared native build / suite | `swift test --cache-path "$PWD/.build/swiftpm-cache" --disable-sandbox --skip-update` with project-local module caches compiled the Debug app, CLI and tests; **24 Swift Testing tests passed**. Includes actual ffmpeg validation/encoding plus synthetic backend recovery. No inference engine was loaded. |
| Earlier focused native pass | After adding `-B` to the isolated Python launch, `swift test --filter 'speech\|kokoro'` with the same local-cache/build flags. **Six test functions passed**, with parameter cases for failures, cancellation/deadline and checkpoint changes. |
| Focused behavior | Helper preparation reused once, ordered multiple artifacts and matching provenance, safe error handling, helper crash/restart, traversal/mismatched response rejection, missing runtime/external symlink refusal, bounded deadline/cancel and owned synthetic descendant termination, compatible resume, incompatible unpublished chunk/encoded invalidation, published immutability, old native record decoding, captured explicit voice/speed without live-path overlap, and pre-write escaped chunk rejection passed. These helpers generate tones and are not speech evidence. |
| Offline Python suite | `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s runtime/kokoro/tests -v`: **7 tests passed**. Covers project-local environment/no global cache fallback, missing-runtime no-download behavior, nested external-link preflight, checkpoint SHA/dtype, pins/lock, and safe real-provider control errors without importing MLX. All three Python sources parse. |
| Ignore policy | Six representative model/interpreter/venv/cache paths were ignored using the project's `.gitignore` in an isolated temporary Git repository; source and lock paths remained unignored. VoiceRelay itself is not a Git repository, so no staging/commit was attempted. |
| CLI with no imported profile | A fresh `/private/tmp` speech attempt captured explicit voice/speed and reached the expected missing project-local runtime error (exit 1), rather than a path-overlap error. No speech helper, audio, feed or download was produced; the isolated temporary workspace was removed afterward. |
| Read-only setup inspection | `runtime_setup.py paths` returned only project-owned paths. `check` returned the expected exit 2 with an actionable missing-runtime message; it downloaded/created no runtime/model. |
| Xcode project/static | Project and app plist lint passed; SwiftPM and Xcode dependency pins match. Added core/helper and runtime source navigation without changing deployment target, shared scheme behavior, or diagnostics. |
| Xcode Debug build-for-testing | **Blocked before app compilation.** Restricted manifest diagnostics initially tried an unavailable user cache. A `CFFIXED_USER_HOME` local-cache experiment progressed to manifest sandbox execution, then failed with `sandbox-exec: sandbox_apply: Operation not permitted`. No permission escalation or GUI automation was requested. This is not a Swift source compile failure or a passed Xcode gate. |
| GUI / Canvas / actual speech | **Not run by the agent.** New Settings controls, preview rendering, explicit runtime installation/download, real MLX/Metal inference and listening remain operator checks. No new runtime-warning result is claimed. |

Initial test failures were test-scope issues: the recovery test held a native
writer lock during resume, and the deadline assertion included a delayed async
test-executor resumption under concurrent ffmpeg work. The corrected tests release
the store before resume and measure the actual helper call; final checks above
passed. The underlying process deadlines use monotonic uptime. SwiftPM emitted
user-cache access and deprecated `--skip-update` warnings; the final source build
emitted no Swift source diagnostics.

Ignored logs are under `var/validation/2026-10-02-kokoro/`: `swift-tests.log`,
`speech-focused-final.log`, `python-tests.log`, and the two blocked Xcode logs. The final full native pass also includes the later folder-confinement and explicit-option regressions. The Xcode attempts
also produced unavailable simulator/profile and beta tooling diagnostics; these
do not establish app runtime behavior.

Remaining gates for this change:

- User Xcode Debug build/Test, Canvas, speech Settings/Inspect/Pause/Resume/Repeat/Quit.
- Clean project-owned interpreter/dependency/model installation, including wheel
  availability, G2P completeness and retained license inventory.
- Real speech codec/decode/completeness and listening; this app's own throughput,
  memory and hours-long resource behavior. Benchmark success is independent evidence.
- Actual Metal cancellation, abrupt-parent-loss cleanup, signed/relocatable runtime
  and complete redistribution review; the development runtime is not app-bundled.
- Existing Safari/HTTP, persistent signed agent/XPC/SMAppService/privacy/Keychain,
  backed-up data adoption, delivery/device/hosting acceptance remain future slices.

Next operator action: follow [the Terminal setup and Xcode speech guide](KOKORO_PROVIDER.md#first-user-run-speech-check-in-xcode).

## October 2 fresh native startup run: warning and interaction both confirmed

The operator reports stopping the previous session, clearing the console, and
restarting execution. The new console is therefore evidence from a fresh run,
not continuation of the earlier paused process. It identifies host macOS 27.2
`26B5091g`, `LSUIElement = true`, activation policy 1, and `NSSceneStatusItem`.
All startup creation/label/menu stages return. The layout-recursion warning then
appears before the first logged `MENU will open`; exact click timing is not
supplied, so this ordering does not identify a particular source assignment.

The same log records two menu openings/closings, the direct **Confirm menu
action** marker, **Quit requested from native menu**, and termination cleanup.
This supports successful native menu presentation, action dispatch, and the
normal Quit path in this fresh run despite the warning. It does not certify
VoiceRelay's Settings/Inspect/fixture interactions or live/speech acceptance.

Additional diagnostics: Intents registration code 4 and linkd connection code
4097 persist; a task-name-port failure appears with an unidentified caller.
Each menu opening also logs `makeKeyWindow` against an AppKit
`_NSGlassEffectWindow` whose `canBecomeKeyWindow` is false. The startup source
creates no NSWindow and makes no key-window or task-port calls. The glass-window
messages coincide with native menu presentation, making framework presentation
the stronger lead; no originating stack or specific defect is established.
Apple's [canBecomeKey documentation](https://developer.apple.com/documentation/appkit/nswindow/canbecomekey)
states that attempts to make an ineligible window key are abandoned. The
subsequent action and Quit markers show that these messages did not block the
observed interactions; they are not blanket evidence of harmlessness in all runs.

Diagnostic disposition: the layout mechanism is localized and independently
reproduced in AppKit-only startup. Keep the production UI and proceed with
development while tracking these runtime warnings and retesting after approved
updates. There is no demonstrated benefit from project recreation or native UI
replacement, and no additional unchanged startup experiment is required now.
Exact internal cause, beta-only attribution, and a warning-free release remain
unresolved. Only documentation and the local feedback draft were updated; no
new build/tests, automated GUI, submission, permission/service change, or live-data
operation occurred.

## October 2 native menu-bar startup reproduces layout recursion

The operator hit `_NSDetectedLayoutRecursion` in `StatusItemStartupRepro` and
supplied `thread backtrace -c 100`. Stop reason is breakpoint 1.1 on the main
thread. Frames 81–85 name the native startup diagnostic's application entry and
`NSApplication.run`; no SwiftUI frame appears. The source imports AppKit only,
creates no ordinary window, and has no VoiceRelay/core/data dependency.

Comparison with the prior MenuBarExtraRepro capture confirms that frames 0–80
match exactly after removing addresses. In particular, frames 40–45 connect the
status-item scene and set its display identifier. Frames 14–18 change a view
frame during layout and post its notification; the AppKit observers request
window placement/layout (5–13), reentering `layoutSubtreeIfNeeded` (0–4).

Conclusion: this warning does not require SwiftUI, VoiceRelay's panel, or the
pipeline. It reproduces in a minimal native AppKit menu-bar-only startup control
with the same immediate framework mechanism. Replacing MenuBarExtra with a
native status item is therefore not a demonstrated remedy. The contrast with
the clean interactive native controls points toward app policy/startup/window
conditions; those factors changed together and are not individually isolated.
An AppKit/runtime defect or environment interaction is the stronger lead, but a
beta-only regression and the exact internal receiver/cause are not established.

The supplied attachment contains the backtrace only, with no StartupProbe console
markers or last-action report. It identifies asynchronous scene-connection work,
not a precise source assignment or whether the operator had clicked the item.
Post-continue menu action, Quit, and responsiveness remain open. This debugger
stop is not a crash. Current Intents/linkd behavior is not established by this
stack; the earlier native logs reproduced those messages without layout warnings.

Updated the diagnosis guide and prepared a local
[Apple feedback draft](../Diagnostics/StatusItemRepro/APPLE_FEEDBACK_DRAFT.md).
No feedback was submitted. Only documentation changed; no new build/core test,
GUI automation, permission/service change, or live-data operation occurred.
The existing successful Debug build/signature evidence remains separate from
operator runtime reproduction and remaining functional acceptance.

## October 2 AppKit variable-width result and native startup control

The operator's next console records a fresh baseline on macOS 27.2 build
`26B5091g`, variable-width native item creation, runtime class `NSSceneStatusItem`,
text, waveform, menu attachment, Quit, and cleanup. No layout-recursion warning
appears in this excerpt. Unlike the square-width run, no ignored mode-change
marker appears. Both native width modes have now completed those recorded stages
without an observed layout warning. Neither excerpt contains menu-opening or
menu-closing markers; actual menu presentation remains unconfirmed by the logs.
Intents/linkd connection/registration errors persist in the variable-width run.

These results weaken an explanation based solely on item width, native waveform
assignment, or the `NSSceneStatusItem` runtime class. They strengthen a lead in
SwiftUI scene/label handling or differences in startup timing and app policy.
The native controls create the item interactively after an ordinary window has
opened; the SwiftUI controls are `LSUIElement` apps creating their item at startup.
No specific framework defect, beta OS cause, or production fix is established.

Added isolated `StatusItemStartupRepro` source, target, and shared scheme. It uses
AppKit only, `LSUIElement = YES`, a variable-width item created during launch,
the waveform image, and a native menu, with no ordinary window. A **Confirm menu
action** item emits a direct selection marker so menu interaction can be observed
without relying on menu-delegate callbacks. This narrows remaining differences;
its exact callback timing and native label/menu content still differ from SwiftUI.

Agent validation on Xcode 27.2 beta `27B5028f` / SDK 27.2: arm64 Debug build and
strict signature verification passed. Generated plist confirms the intended
executable, isolated bundle identifier `org.voicerelay.diagnostics.startup`,
minimum macOS 27.0, and `LSUIElement` enabled. Binary inspection found no direct
SwiftUI or VoiceRelayCore dependency. All preexisting diagnostic project objects
were preserved except required group/target membership additions. All 31 files
captured in the current production source/test/packaging/notices/main-project
baseline retain their hashes. No production behavior changed or core tests reran.

The new scheme's Build/Run/Profile bindings match its target and product. Static
inspection also found an existing operator-edited Run override in
`MenuBarExtraRepro.xcscheme`: it builds MenuBarExtraRepro but launches
StatusItemLifecycleRepro. That setting was preserved. Source/console identity is
used for these results, rather than inferring the executable from the scheme name.
Other Run bindings match their named targets.

Build log: `/private/tmp/voicerelay-layout-startup-build.log`. Sandbox logging/
CoreSimulator service diagnostics and skipped App Intents metadata extraction
were present; no Swift source warning/error was observed. Release and the new
probe's GUI/runtime behavior remain unrun. No GUI automation, service enrollment,
permission change, or live-data operation occurred. The manual startup comparison
is documented in the [diagnosis guide](../Diagnostics/StatusItemRepro/LAYOUT_DIAGNOSIS.md).

## October 2 AppKit square-width operator result

The operator reports completing the lifecycle diagnostic without hitting the
layout-recursion breakpoint. The supplied console contains the AppKit probe's
baseline markers and host version 27.2 build `26B5091g`. It records square-width
item creation, runtime class `NSSceneStatusItem`, text assignment, waveform
loading/assignment, native-menu attachment, Quit, and owned-item removal during
termination. No layout-recursion warning appears in the supplied log. The
operator also reports no debugger prompt; no warning backtrace is needed when
the debugger has not stopped.

The log includes `Ignored: restart the app to change creation mode` after
square-width creation. Source inspection confirms this guard leaves the existing
item unchanged. This run does not exercise variable-width creation; that requires
a fresh process choosing 1b first. The operator's general report says all tests
completed, but the excerpt has no `MENU will open`/`MENU did close` markers, so
actual menu presentation is not established by these markers. Preserve the
reported outcome while keeping that instrumentation limit explicit.

This provides a useful negative control: square-width native creation and the
recorded label/menu updates did not reproduce layout recursion in this run,
although the runtime item class matches the `NSSceneStatusItem` path in the
SwiftUI trace. The class alone is not sufficient to explain the warning. SwiftUI
scene/label sizing, startup timing, activation policy, and ordinary-window
presence remain differences to isolate; no specific defect or fix is proven.
Intents/linkd errors still occur in this run without an observed layout warning,
adding evidence to investigate those messages separately.

Only documentation was changed for this result. No new build, core test, GUI
automation, permission change, or production/live-data operation was performed.
The next narrow operator check is a fresh `StatusItemLifecycleRepro` run choosing
variable width first, then label, waveform, menu attachment and opening, with
console markers retained. The production UI remains unchanged.

## October 2 fresh symbolic-breakpoint capture: SwiftUI control

The operator supplied a new `thread backtrace -c 100` capture. The main thread
stopped at breakpoint 1.1 in `_NSDetectedLayoutRecursion`, confirming the recreated
breakpoint catches the warning path. Frame 86 identifies the executable as
`MenuBarExtraRepro.debug.dylib` and source `MenuBarExtraReproApp.swift`; frames
82–84 show SwiftUI startup. This is evidence from the SwiftUI window-style
control, not a run of the new AppKit-only `StatusItemLifecycleRepro` probe.

Frames 40–45 show status-item scene connection. During the original layout,
frames 14–18 show a view frame change and frame-change notification; AppKit
observers then reenter window placement and `_layoutViewTree` (5–13), requesting
layout again (0–4). This reproduces the earlier mechanism with a slightly
different inner window-layout path. The attachment contains no `[LayoutProbe]`
markers, last-action report, or subsequent GUI result. A breakpoint stop is not
evidence of a crash. Native item creation without SwiftUI remains untested.

Static reinspection confirms all four shared diagnostic schemes bind Run to
their matching target, product, and single intended source file. No source or
project changes, new build, automated GUI execution, or live-data operation were
needed for this analysis. The next operator check is explicitly
`StatusItemLifecycleRepro → My Mac`, expecting an ordinary control window and
`[LayoutProbe] BASELINE` messages before any status item is created.

## October 2 layout localization and AppKit lifecycle probe

Reanalysis of the operator's existing backtrace localizes the recursion to
status-item scene connection: AppKit layout changes a view frame, posts its
frame-change notification, and an AppKit observer requests window frame/display
work that reenters layout. The chain contains no VoiceRelay callback beyond
startup. Receiver identity and the underlying trigger remain unconfirmed; this
is not certification of an Apple bug or a root-cause fix. Intents/linkd remains
a separate diagnostic. The operator reports Thaw installed but currently stopped;
there is no evidence that it caused this warning.

Added the isolated `StatusItemLifecycleRepro` AppKit-only diagnostic target,
shared scheme, and [manual diagnosis guide](../Diagnostics/StatusItemRepro/LAYOUT_DIAGNOSIS.md).
The user controls bare-item creation (square or variable width), text, waveform,
menu attachment, and menu opening separately. Console markers and a symbolic
breakpoint are intended to identify the first triggering stage. An ordinary
window provides a baseline before any status item exists. No production source
or UI behavior was changed.

Current read-only environment inspection: Xcode 27.2 beta build `27B5028f`, SDK
27.2, host macOS 27.2 build `26B5091g`. The new target's arm64 Debug build passed
using isolated DerivedData at `/private/tmp/voicerelay-layout-lifecycle`; strict
signature verification passed. Its generated plist has the intended executable,
minimum 27.0, and no `LSUIElement`/`LSBackgroundOnly` flags. Binary inspection
shows no direct SwiftUI or VoiceRelayCore dependency. All four diagnostic scheme
bindings passed static checks, and existing project objects were preserved
apart from required membership additions. All 34 captured production-file hashes
remained unchanged. No core tests were rerun for this isolated diagnostic addition.

Build log: `/private/tmp/voicerelay-layout-lifecycle-build.log`. Build-tool sandbox
service/cache diagnostics and skipped App Intents metadata extraction were
present; no Swift source warning/error was observed. Release for this new probe,
GUI launch, breakpoint capture, and runtime warning comparison remain unrun.
No automated computer use, permission change, service enrollment, or live-data
operation occurred. Existing production interaction, speech, and live acceptance
gates remain open as recorded below.

## October 2 independently created default-app control

The operator reports manually creating and running a fresh Hello World macOS app
in Xcode with its default Swift code. The supplied excerpt reproduces the Intents
process-instance registration code 4 message and `com.apple.linkd.autoShortcut`
connection/registration code 4097 with retries. This project was created by the
operator independently of VoiceRelay and the agent-created diagnostic project.
Its source, settings, exact SDK/build versions, and GUI behavior were not
independently inspected; this is operator-reported control evidence.

This establishes that these Intents/linkd messages can occur without VoiceRelay's
implementation or its custom project wiring. A shared framework/runtime,
Xcode-launch environment, or per-user/system-service condition is the stronger
lead. It does not identify which component is at fault or confirm the beta OS
as the cause. Recreating VoiceRelay's project or changing its pipeline is not
supported as a remedy for these reproduced messages.

The supplied Hello World excerpt does **not show layout recursion** or the
task-name-port line. That is an observation about the excerpt, not certification
that neither can occur during the app's full lifetime. Keep the two original
warning categories distinct: Intents/linkd reproduces in the default app, while
the prior status-item backtrace and both menu-bar-style excerpts remain the
evidence for the layout warning. A MenuBarExtra/status-item lifecycle issue
remains a plausible layout explanation, separate from the Intents registration
failure; no common cause is established.

No new source/build/test, GUI automation, permission change, or live-data operation
was performed for this record. Retain the current production UI and tracked
runtime-diagnostic disposition while validating actual behavior. The default-app
result does not substitute for remaining VoiceRelay interaction or live gates.

## October 2 Xcode 27.2 beta and reboot retest

The operator reports installing/testing Xcode 27.2 beta, rebooting the Mac,
successfully building VoiceRelay, and obtaining another console excerpt. The
configuration, exact Xcode build number, SDK, and current macOS build number were
not supplied. This is operator-reported build/runtime-log evidence; no agent
build or environment inspection was performed for this retest.

The excerpt still contains the Intents/process-instance registration code 4
message, `com.apple.linkd.autoShortcut` connection/registration code 4097 with
retries, and the AppKit layout-recursion warning. The task-name-port line from
the earlier diagnostic-app excerpts is not shown here; those were different
applications/runs, so this does not establish that it was fixed. No termination
line or new stack is supplied. Fresh Settings/Inspect/fixture/Quit acceptance is
not established by this excerpt; prior visible-panel evidence remains historical.

Outcome: this Xcode update plus reboot did not eliminate the two original warning
categories in the reported VoiceRelay run. It weakens an explanation limited to
the older Xcode 27.0 build or a transient condition cleared by reboot. It does not
identify the originating component, confirm a macOS beta defect, distinguish the
update's effect from the reboot's effect, or prove that the newer run has the
same internal call sequence as the earlier backtrace. The two independent style
diagnostics have not been separately reported under Xcode 27.2 beta.

Retain the current UI and tracked-diagnostic disposition, conditional on normal
interactive operation. Keep build success, warning presence, functional GUI
acceptance, and core/live acceptance separate. The next useful development work
is unchanged; repeating the same rebuild/reboot without a new observation is not
a further diagnostic result. No source, project setting, dependency, service,
permission, or live-data change was made in response to this retest.

## October 2 operator menu-style results

The operator supplied console excerpts labeled `MenuBarExtraReproApp` and
`MenuStyleReproApp` after running the comparison. Both contain the following:

| Diagnostic | `.window` excerpt | `.menu` excerpt |
| --- | --- | --- |
| Asynchronous process-instance registration / Intents message | Present | Present; the excerpt starts midway through the registration message |
| `com.apple.linkd.autoShortcut`, Cocoa code 4097, retries | Present | Present |
| `layoutSubtreeIfNeeded` / layout recursion warning | Present | Present |
| Unable to obtain a task name port right, kernel failure 0x5 | Present | Present |

The `.menu` excerpt is truncated at its beginning and end. Neither excerpt
includes timestamps, an action marker separating launch from menu opening,
the actual executable/debugger configuration, or an explicit open/Quit result.
They establish the presence of these messages in the operator-labeled runs;
they do not certify every GUI control, absence of a crash outside the excerpt,
or the warning's precise trigger. Earlier operator evidence of a visible
VoiceRelay panel and reported local fixture completion remains valid.

Conclusion: the native `.menu` comparison did not eliminate either original
warning category in these runs. The symptoms are not exclusive to window-style
presentation or the richer VoiceRelay panel. This strengthens the shared
MenuBarExtra/AppKit/runtime lead without establishing a specific OS defect,
the beta OS as the cause, or a causal relationship between Intents and layout.
There is no demonstrated warning-related benefit from changing the production
panel to a native menu. Retain the current window-style VoiceRelay UI, track the
diagnostics, and retest the same schemes after future approved updates.

The task-name-port line is an additional process-access diagnostic. Apple's
[`es_event_get_task_name_t` documentation](https://developer.apple.com/documentation/endpointsecurity/es_event_get_task_name_t)
describes the corresponding class of task-port acquisition. These particular
logs do not identify its caller, target-process role, or functional consequence.
Source searches found no direct task-port API calls in VoiceRelay or the two
menu diagnostics. No permission/signing changes or process inspection were
performed in response to that line.

This update records operator evidence only. No new code, build, suite run, GUI
automation, service reset, or live-data operation was performed. The style
experiment's warning comparison is now recorded; per-run launch/click timing,
responsiveness/Quit results, Canvas, and the remaining VoiceRelay interaction
checks remain separate acceptance observations.

## October 2 menu-style experiment

The operator chose continued development with runtime warnings tracked, a separate
native-menu experiment, and retesting after future OS/Xcode updates. They identify
their installed macOS as a beta used for development. That is a possible
contributor, not a confirmed explanation for either warning category.

`Diagnostics/StatusItemRepro/MenuStyleReproApp.swift` now defines an independent
`MenuStyleRepro` app and shared Xcode scheme. It uses explicit `.menu` style,
ordinary native menu items, the waveform label, and a Quit action. It imports no
VoiceRelay core, loads no data/configuration, and performs no processing. A named
inert content PreviewProvider is source-local; its Quit action does nothing.
The window-style diagnostic and the VoiceRelay production UI retain their source.
Because native menu items replace fixed-width panel content, the experiment
compares style plus presentation and cannot prove a modifier-only cause.

Inspection found the saved `MenuBarExtraRepro` scheme's Run action pointing at
`WindowRepro.app`, although its Build action targeted MenuBarExtraRepro. The Run
product/target reference was corrected to MenuBarExtraRepro. Its user-selected
unchecked **Debug executable** setting was preserved. This mismatch limits the
interpretation of earlier per-scheme runtime comparisons; it is a diagnostic
launch configuration issue and does not establish the cause of VoiceRelay's logs.
The guide explicitly checks the intended executable and enables the debugger
consistently for the two warning-comparison runs.

| Check | Result and scope |
| --- | --- |
| Project/scheme structure | `plutil -lint` passed. All three targets compile exactly their own source file, and all Build/Run/Profile references match their target/product. No package dependencies are present. |
| MenuStyleRepro Debug | `xcodebuild` passed for arm64/My Mac with temporary DerivedData/module-cache directories and no escalation. |
| MenuStyleRepro Release | The same targeted build passed in a separate temporary DerivedData/module-cache directory. This is a diagnostic Release build, not a VoiceRelay Release gate. |
| Built artifacts | Both Debug/Release strict signature checks passed. Generated plist and Mach-O checks confirm minimum/SDK 27.0, the intended executable/bundle identity, LSUIElement=true, and no LSBackgroundOnly flag. |
| Final source diagnostics | Neither final build emitted a Swift source warning/error. Both emitted the build-tool warning **Metadata extraction skipped, no AppIntents.framework dependency found**. This is separate from runtime linkd registration/connection errors. The restricted build environment also logged unavailable Simulator/logging-service diagnostics; both macOS builds completed. |
| Preservation | SHA-256 checks confirm all 40 sampled existing source/test/notice/packaging/main-project/pin/sample-config and baseline diagnostic files remain unchanged. The intentionally edited diagnostic project/scheme and documentation are outside this unchanged set. No live data or Python reference was written. |
| Runtime and Canvas | Not run by the agent. Menu opening/Quit, warning comparison, and Canvas rendering remain operator checks. No change in runtime warnings is claimed. |

The first Debug attempt using `#Preview` failed when the restricted environment
could not sandbox the compiler macro plugin (`sandbox-exec: sandbox_apply:
Operation not permitted`). The new diagnostic uses the supported PreviewProvider
form instead and both final builds passed. No compiler security option was
disabled and no additional permissions were requested. Existing VoiceRelay
previews were not changed. The core suite was not rerun for this isolated UI
diagnostic addition; focused target/project checks were used.

Final build logs are temporary evidence:
`/private/tmp/voicerelay-menu-style-debug-build.log` and
`/private/tmp/voicerelay-menu-style-release-build.log`. The initial macro-failure
log is retained at `/private/tmp/voicerelay-menu-style-debug-preview-macro-build.log`.

See the [manual comparison and GUI checklist](../Diagnostics/StatusItemRepro/README.md).
It records launch/click warning triggers per style, required debugger settings,
Settings/import/inspection, stable UUID and zero synthesis on repeat, pause/resume,
and normal quit/relaunch. If the small fixture finishes before Pause can be used,
that gate must be reported as not exercised. Future update comparisons retain
versioned observations. No update, automation, service reset, or live cutover is
performed by this experiment.

## October 2 launch investigation

### Operator follow-up: interface now visible

The operator subsequently reports that both requested launch checks work properly
and confirms that VoiceRelay appears in the menu bar; the initial absence of an
ordinary startup window was a discoverability misunderstanding. The supplied
screenshot shows the VoiceRelay panel with **Fixture published locally**,
**Validated M4A (mock tones)**, and **Current — isolated RSS**. This is operator
GUI evidence of the visible panel and reported fixture completion, not independent
inspection of that run's files, human speech acceptance, or acceptance of every
control. The operator continues to observe the console warnings. A separate
warning matrix for every scheme/launch method was not supplied.

Current disposition: retain the Intents/linkd messages and the supplied AppKit
layout trace as nonblocking runtime diagnostics under investigation, given the
now-working interface. There is no confirmed Apple diagnosis or documented fix
for these exact messages on this installed OS/Xcode combination. Reproduction
outside VoiceRelay and the AppKit-only portion of the layout trace weaken the
project-retrofit hypothesis; they do not prove a particular system defect.

Focused source inspection again found no AppIntents/AppShortcut registration,
process-instance-registry call, or direct AppKit layout call/override. The UI path
most directly related to the supplied layout trace is
`MenuBarExtra(...).menuBarExtraStyle(.window)` in
`Sources/VoiceRelayApp/VoiceRelayApp.swift`. Settings and inspection activation
calls are explicit button actions; no such action appears in the supplied launch
trace. Automatic framework registration is still an inference for Intents/linkd,
not a diagnosed application call site. AppKit documents that it calls
[`layoutSubtreeIfNeeded`](https://developer.apple.com/documentation/appkit/nsview/layoutsubtreeifneeded())
automatically before drawing constraint-based views. The
[similar Apple Developer Forums thread](https://developer.apple.com/forums/thread/806471)
does not provide a confirmed root-cause fix; its Apple DTS response discusses
console filtering, which changes visibility rather than behavior.

For that operator follow-up, no application or Xcode settings change was made to
suppress the messages, and no new build/test was run for its documentation-only update. Settings/import,
inspection, cancellation/resume, repeated fixture runs, and normal quit remain
manual interaction gates. If a visible defect appears, capture its own trigger
and stack. A minimal `.menu` style comparison was proposed as a further isolation
step; its subsequent implementation is recorded above and is not a verified fix. Any comparison with
future organization-approved OS/Xcode updates must retain the observed versions
and results; no fixed release is identified.

### Initial report and read-only checks

The initial October 2 report described the same Intents/linkd and layout warnings
in the prototype apps, with no windows appearing. Visible operation had not passed acceptance.
The absence of a startup window is expected for VoiceRelay and MenuBarExtraRepro,
but each must still expose a usable waveform menu-bar panel. WindowRepro must
present an ordinary window. The supplied console excerpt alone does not establish
which executable ran, whether execution was paused, or whether a menu item appeared.

Read-only inspection of
`/path/to/home/Library/Developer/Xcode/DerivedData/StatusItemRepro-dwefklujjgzmkjdbwdsyitmrponz`
found only `Debug/MenuBarExtraRepro.app`; inspected build/run manifest records name
MenuBarExtraRepro. No WindowRepro bundle was present in that project's products.
This does not rule out a launch from another location. The ordinary-window runtime
comparison remains unverified. Both saved shared schemes point to their matching
target/product, launch automatically in Debug, and attach LLDB. No concrete project
wiring defect was found. The saved main-project breakpoint file contains no entries;
this does not establish current debugger state or breakpoints elsewhere.

The permitted command-line environment still reports macOS 27.2 (26B5091g) and
Xcode 27.0 (27A266a). The previously compiled diagnostic bundles remain in
`/private/tmp/voicerelay-status-diagnostics/Build/Products/Debug`. Both passed renewed
`codesign --verify --strict --verbose=2` checks. Both specify minimum/SDK 27.0;
WindowRepro has neither LSUIElement nor LSBackgroundOnly set, while MenuBarExtraRepro
has LSUIElement=true and no LSBackgroundOnly flag. These are artifact checks,
not runtime results. No new compilation, test suite, or GUI run was performed.
A read-only process listing was denied by the sandbox; no process-state conclusion
is claimed and no permission escalation was requested.

The [manual guide](../Diagnostics/StatusItemRepro/README.md) now starts with a Finder
launch of the prepared WindowRepro, an Xcode run with **Debug executable** unchecked,
and a debugger-attached comparison if the first two work. The operator will report
window/Dock behavior, any launch alert, and Running/Paused status. Missing UI must
not be dismissed as console noise. No application behavior, project settings, live
data, or system services were changed speculatively.

## Minimum version update

The operator reported a successful Xcode build, with a warning that the app's
`LSMinimumSystemVersion` of 14.0 was below the effective deployment target of 14.6.
The build configuration was not specified. This is operator-reported build evidence,
not a GUI, Canvas, test, resource, or signing acceptance result.

At the user's request, the package platform, project Debug/Release deployment
settings, app target Debug/Release overrides, and bundle minimum now specify
macOS 27.0. The app overrides no longer use Xcode's recommended deployment target.
`plutil -lint` passed for project and bundle metadata. A parsed-settings check
confirmed 27.0 for app, CLI, and tests in Debug/Release, explicitly or by project
inheritance, plus the matching bundle/package minimums. Direct manifest type-checking
passed with Swift tools 6.2 API availability and a permitted temporary module cache.
No app rebuild was performed by the agent for this change. The operator subsequently
reported a successful Xcode build without compile errors after the minimum-version
update. The configuration was not specified, and runtime console warnings persist.

## Operator runtime diagnostics under investigation

The operator supplied console messages about process-instance registration and
`com.apple.linkd.autoShortcut` connection errors, a layout recursion warning, and
`Debug session ended with code 9: killed`. This does not identify the cause of
termination or establish that the layout warning caused it.

An earlier operator report confirmed a build without compile errors and repeated
the registration/connection and layout warnings, with no termination line in the
excerpt. That report alone did not establish GUI or fixture acceptance; the
October 2 follow-up above provides the subsequent visible-panel evidence.

The installed SDK's `FoundationErrors.h` defines code 4097 as
`NSXPCConnectionInterrupted`. The repeated connection/registration messages are
retries involving the same `com.apple.linkd.autoShortcut` service, rather than
distinct pipeline-stage failures. Their origin in automatic framework registration
is a working inference from the log and absence of application AppIntents code;
the underlying service failure has not been diagnosed. The layout warning is a
separate nested-layout diagnostic. The operator has now supplied its stack.

Source inspection found no AppIntents/AppShortcut registration, AppKit layout
override, or direct `layoutSubtreeIfNeeded` call. The app uses SwiftUI MenuBarExtra,
Settings/window opening actions, and explicit modal file selection. A framework
call stack was obtained before choosing a layout fix. No speculative UI change or
system-service reset was made.

The supplied backtrace localizes the immediate recursion to status-item scene
initialization inside AppKit:

- Frames 43–49: `NSStatusItem`, `NSSceneStatusItem`, and the status-item variant
  scene delegate connect/configure the status-bar item.
- Frame 21 begins `NSView layout`; frames 18–20 update view geometry, then frame
  17 posts a frame-change notification.
- Its observer calls `NSWindow _setFrameCommon:display:fromServer:` at frame 10.
  Display then requests `layoutSubtreeIfNeeded` at frame 4 while the original
  layout is still active, reaching `_NSDetectedLayoutRecursion` at frame 0.
- No VoiceRelay layout/action callback appears in that sequence. The only shown
  application frame is `main` at frame 89, beneath SwiftUI's application entry.

For this VoiceRelay trace, the strongest inference is an AppKit status-bar
initialization issue in the MenuBarExtra lifecycle. The trace does not prove a
specific OS defect or rule out every influence of declarative view configuration. It provides no evidence of
a pipeline failure or a faulty application `layout` override. The displayed stop
reason is debugger instruction stepping; this backtrace is not a crash report.
The separate Intents/linkd service issue remains unresolved.

Manual next check: disable the diagnostic symbolic breakpoint and continue. Check
menu opening, Settings/inspection, and the isolated fixture explicitly. If they
work without visible layout defects or spontaneous termination, retain this as a
nonblocking runtime warning pending framework/minimal-reproduction investigation.
Record whether Xcode Stop was pressed before the earlier code 9. If termination
was spontaneous, inspect the matching app report's exception and termination reason.
GUI/runtime acceptance remains pending until the operator reports those checks.

Reproduction steps used for the layout stack: open the Breakpoint navigator (⌘8),
click **+ → Symbolic Breakpoint**, enter `_NSDetectedLayoutRecursion` as the symbol,
and run again. If the breakpoint is hit, enter `bt` in the debugger console and
retain the output plus the action that triggered it. Leave the Library field empty.
No desktop automation is required. A similar warning has been reported with
AppKit-only stacks, including status-bar contexts, on
[Apple Developer Forums](https://developer.apple.com/forums/thread/806471);
those reports do not establish the root cause in VoiceRelay.

## Xcode project audit and independent diagnostics

The project-recreation hypothesis was checked against the current project and
the operator's built Debug artifacts in the observed VoiceRelay DerivedData
directory. No concrete wiring defect was found:

- App, CLI, and test targets each compile their intended entry/test source once
  and each link the local `VoiceRelayCore` package product once. The app does not
  separately compile a second copy of the core.
- The shared scheme launches the app target. Root and workspace dependency pins
  match. Debug/Release deployment settings are 27.0, explicitly or by inheritance.
- The built app uses `org.voicerelay.prototype`, `VoiceRelayApp`, LSUIElement=true,
  minimum macOS 27.0, and SDK macosx27.0. Its debug dylib's load command also
  records minimum/SDK 27.0. App Sandbox is disabled as configured.
- The app's core bundle is present. Its fixture is at
  `Contents/Resources/VoiceRelay_VoiceRelayCore.bundle/Contents/Resources/article.html`,
  the normal macOS bundle layout, and matches the saved source fixture exactly.
  The generated `Bundle.module` accessor checks the app's resource directory.
  All packaged acknowledgements match source. Strict signature verification passed;
  verbose signing inspection identifies the local signature as ad hoc.

The Xcode-built Debug CLI was executed in a new owned temporary workspace with
no implicit `config.toml`. Its first fixture run published one episode from seven
chunks. The second synthesized zero chunks. Read-only SQLite/hash checks confirmed
one episode, unchanged identity/publication date, PUBLISHED state, and identical
M4A/feed bytes. This is new validation of the Xcode-built CLI and shared pipeline;
it does not validate app GUI behavior or live speech/delivery. No live data was used.

A separate dependency-free project now exists at
`Diagnostics/StatusItemRepro/StatusItemRepro.xcodeproj`. `WindowRepro` is an ordinary
SwiftUI window control; `MenuBarExtraRepro` creates only a waveform status item with
window-style content. Neither imports VoiceRelay, uses its package/custom plist,
reads a profile, or starts work. Both use Xcode-generated Info.plists and separate
diagnostic identifiers.

Both Debug schemes built successfully with `xcodebuild`, temporary DerivedData and
module-cache directories, macOS 27 SDK, and no permission escalation. Both bundles
passed strict signature verification and minimum-version checks; only the menu-bar
diagnostic has LSUIElement=true. Logs are temporary development evidence:
`/private/tmp/voicerelay-window-repro-build.log` and
`/private/tmp/voicerelay-menu-repro-build.log`. No diagnostic GUI was launched or
automated. Runtime comparison remains the operator's next check.

See [the beginner-friendly diagnostic guide](../Diagnostics/StatusItemRepro/README.md)
for exact Xcode steps, a results table, and stack capture if needed. Recreating
the production project is not justified by current evidence. A warning reproduced
in the minimal menu-bar app would substantially weaken the retrofit hypothesis;
a clean control with warnings only in VoiceRelay would justify further comparison.

## Migration and Xcode checks

The new project has app, CLI, and core-test targets, a shared `VoiceRelay` scheme,
and a local Swift package dependency on the unchanged native core. The package
and Xcode workspace retain identical dependency locks.

| Migration check | Result and scope |
| --- | --- |
| Selective transfer | 29 runtime/test/build files match the earlier native source byte for byte: Sources, Tests, Packaging, Acknowledgements, manifest, pins, sample TOML, build script. Docs were updated separately. No live config, Python source, old build output, or Git metadata was migrated. |
| Reference preservation | All 69 original reference/config/state/artifact/media files, all 33 migration-source files, and the 47-file earlier native installed snapshot match their private SHA-256 baselines. No original file was deleted. |
| Project structure | `plutil -lint VoiceRelay.xcodeproj/project.pbxproj Packaging/Info.plist` passed. Parsed target/source/product references, scheme/workspace XML, and matching package locks passed focused structural checks. This is not a compilation result. |
| Script syntax | `bash -n scripts/build-app.sh` passed. |
| Native recovery-driver compilation | `swiftc -I Sources/CSQLite -module-cache-path /private/tmp/voicerelay-migration-modules scripts/check-process-recovery.swift -o /private/tmp/voicerelay-check-process-recovery` passed with no diagnostics. Direct compilation used permitted temporary output/cache paths. |
| Native recovery-driver execution | All five SIGKILL/restart/idempotence cases passed against the previously built Debug CLI in `/private/tmp/voicerelay-native/.build/out/Products/Debug/voicerelay`. Fresh owned temporary workspaces, one stable episode, preserved reserved dates, zero unnecessary synthesis after encode, and unchanged repeat audio/feed bytes. The CLI was built before relocation from the byte-identical source; this does not validate the new Xcode build. |
| Relocated SwiftPM suite | Blocked before source compilation by the manifest sandbox restriction below. No new test pass is claimed. |
| Xcode Debug build-for-testing | Blocked during manifest resolution by the cache write restriction below. App/CLI/test compilation, resource embedding, signing, and GUI launch remain operator gates. Release was not attempted after the same resolution prerequisite failed. |

SwiftPM's fresh `swift test` attempt used cache/config/security/module paths in
`/private/tmp` but stopped before source compilation with
`sandbox-exec: sandbox_apply: Operation not permitted`. Xcode's Debug
`build-for-testing` attempt used temporary DerivedData, package checkouts, and
repository caches. The five pinned dependencies were checked out from existing
caches, but manifest resolution stopped when diagnostics emission attempted to
write `/path/to/home/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/voicerelay.dia`
outside the permitted workspace. These are environment/access failures; neither
attempt supplies a passing relocated build or test result. No escalation or
desktop permission request was made.

## Historical Slices 1–2 checks before relocation

| Check | Command / observation | Result and scope |
| --- | --- | --- |
| Environment | `sw_vers`, `xcodebuild -version`, `swift --version`, SDK lookup, tool version and signing identity inspection | arm64; macOS 27.2, Xcode 27.0, Swift 6.4, macOS 27 SDK, ffmpeg/ffprobe 9.0.2; no valid signing identity |
| Dependencies | `swift package resolve`; inspected pinned manifests, public APIs, and redistribution notices | SwiftReadability 0.3.3, SwiftSoup 2.13.6, TOMLDecoder 0.4.5 and resolved transitive revisions recorded; notices copied |
| Native suite and debug app/CLI build | `swift test` | 16 Swift Testing tests passed; URL and recovery tests each have five parameter cases. XCTest's separate zero-test message is not the test count. Includes actual encoder/probe/decode operations and a first-creation /private/tmp alias regression. |
| Configuration compatibility | Native `voicerelay doctor --config` and isolated `fixture --config` against the existing customized file | Parsed read-only; existing media/tool presence observed; explicitly reported Safari, speech, delivery and worker gates. Fixture produced seven chunks, then resumed with zero new synthesis. No live state opened or created. |
| Actual process termination | `python3 scripts/check-process-recovery.py <debug-cli>` | All five owned-child SIGKILL/restart/idempotence cases passed: completed chunk, encoded, audio placed, episode committed, feed replaced. Stable IDs/dates, one episode, unchanged repeat bytes, OS lock release verified. |
| Script syntax | `bash -n scripts/build-app.sh`; Python AST parse of recovery driver | Passed |
| Reference preservation | SHA-256 comparison of the private pre-implementation baseline | All 69 inspected reference/config/state/artifact/media files unchanged, including customized TOML and published data. This is local preservation evidence, not external server integrity. |

The suite covers anchored paths, tilde expansion, customized encoding settings, legacy backend
retention, safe errors, HTTPS and path/privacy rules, non-native/newer database rejection,
competing writer exclusion, semantic/narration order/Unicode/bounds, chunk provenance,
multiple lossless artifacts via another backend, repeated UUID/GUID/date/audio/feed preservation,
exception recovery at five boundaries, same-size damaged chunk recovery, damaged published
audio blocking feed replacement, missing-feed repair without TTS, and tool timeout/cancellation.

Initial failures in generic TOML container handling and filesystem URL restoration were
localized and repaired. A later callback-binding compile failure was corrected by labeling
the UI progress callback explicitly. The corrected full test run passed. These are code-fix
results; the first restricted compiler attempt also hit a sandbox/cache-access limitation,
which was resolved by building with authorized normal Xcode compiler-cache access.

A fresh fixture under `/private/tmp` exposed Foundation's differing canonical URLs for existing
versus not-yet-created paths. Path comparisons now resolve existing filesystem ancestors with
`realpath`, and symlink checks stop at the canonical workspace boundary. The new regression
creates a fixture through `/private/tmp`, resumes it through `/tmp`, and verifies unchanged
identity and zero synthesis. Internal symlink rejection remains covered by its own test.

## Historical packaging and launch checks

The initial release app/CLI builds and `scripts/build-app.sh release` passed. The resulting
arm64 app contains its SwiftPM fixture bundle and redistribution notices; `plutil -lint` and
`codesign --verify --strict --verbose=2` passed. A restricted `open` returned LaunchServices
error -10827 despite valid executable/plist/signature. Authorized normal-context `open`
succeeded and a process query confirmed the app executable running.

The final corrected `swift build -c release` passed for both app and CLI. Packaging initially
failed on a repeated build because copied dependency license files retained read-only modes.
The script now replaces those generated copies with `cp -fR`; two consecutive release app
packaging/signature-verification runs passed. The final bundle was transferred with a guarded
hash check that refused external changes, then reopened successfully in its installed path.

No GUI controls or Canvas previews were inspected. The user subsequently specified
manual GUI/Mac acceptance and no automated computer use. The earlier launch/process
smoke check is historical evidence and is not GUI acceptance or an Xcode launch check.

## Outstanding acceptance gates

- Actual Xcode Canvas rendering of the six named source-local previews; build coverage only.
- Fresh relocated SwiftPM build/test, Xcode Release/test-bundle builds, and the core
  suite under Xcode. The operator has reported a successful app build; the observed
  Xcode Debug app passed resource/signature/metadata inspection and its CLI passed
  cold/repeat fixture validation. Those checks do not establish all build/test gates.
- Settings/import, inspection, fixture pause/resume/repeat, and normal quit acceptance
  by the user. Menu-bar visibility and a panel showing fixture completion now have
  operator evidence; this does not establish all interactions. Do not request
  computer-use permissions.
- Exact diagnostic scheme/launch warning matrix and any further runtime-warning
  isolation. Operator-labeled `.window` and `.menu` excerpts both show Intents/linkd,
  layout recursion, and task-name-port diagnostics; the style change did not
  eliminate them. Exact launch/click timing, debugger/executable configuration,
  explicit diagnostic open/Quit results, and root cause remain unresolved. The new
  `.menu` diagnostic builds in Debug/Release; Canvas remains unverified.
- Representative real-source extraction completeness, consent/login/error-page handling, and
  bounded HTTP retrieval. Slice 2 intentionally loads a saved synthetic fixture.
- Real Safari hierarchy/reconciliation and privacy access, first interactively and then by the
  final scheduled executable. No real Safari entries were ingested or altered.
- Intelligible speech and listening acceptance remains open. The October 2 benchmark
  now selects Kokoro via mlx-audio; synthetic contract tests still produce tones.
- Persistent helper/agent bundle, versioned XPC, SMAppService authorization, automation baseline,
  scheduled retries, user login/restart/sleep-wake, process-group cleanup for future helpers,
  and actual-agent Full Disk Access/Keychain checks. No worker is enrolled.
- Backed-up native adoption of Python schema/data/artifacts. Python/live databases are refused.
- Physical power-loss behavior, large/long article resource limits, disk-full error injection,
  mounted-volume loss during an active write, and production-grade settings changes/regeneration.
- Actual live media-host/Tailscale checks, WebDAV secret and destination setup, deliberate
  complete-feed upload, authenticated remote XML, and Overcast discovery/download/playback.
- Native Caddy service equivalence/ownership and intentional cutover; none attempted.

No Python test suite was rerun: no Python code changed. Existing external delivery experiments
remain historical evidence. No network article, credential, feed upload, model download,
automation enrollment, live migration, or infrastructure change was part of these checks.

## Operator validation from the new root

In Xcode, open `VoiceRelay.xcodeproj`, choose **VoiceRelay → My Mac**, build with
⌘B, run with ⌘R, and run the existing core suite with ⌘U. The app uses a waveform
menu bar item and has no Dock icon. Quit another VoiceRelay copy first. Inspect the
six previews in `Sources/VoiceRelayApp/VoiceRelayApp.swift` with Canvas enabled.

For repeatable command-line evidence in your normal Terminal:

```sh
cd /path/to/VoiceRelay
swift test
swift build -c release
./scripts/build-app.sh release
native_bin="$(swift build --show-bin-path)"
swift -I Sources/CSQLite scripts/check-process-recovery.swift "$native_bin/voicerelay"

xcodebuild -project VoiceRelay.xcodeproj -scheme VoiceRelay \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile build-for-testing
xcodebuild -project VoiceRelay.xcodeproj -scheme VoiceRelay \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile test-without-building
xcodebuild -project VoiceRelay.xcodeproj -scheme VoiceRelay \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile build
codesign --verify --strict "$PWD/DerivedData/Build/Products/Release/VoiceRelay.app"
plutil -lint "$PWD/DerivedData/Build/Products/Release/VoiceRelay.app/Contents/Info.plist"
```

Confirm `Contents/Resources/VoiceRelay_VoiceRelayCore.bundle` and
`Contents/Resources/Acknowledgements` exist in the Xcode app. For manual acceptance,
import the external customized profile read-only, select a dedicated empty fixture
folder, run once, inspect blocks/chunks, then run again and confirm zero new synthesis.
Exercise Pause and Quit during work and explicitly resume. Verify original TOML/live
data are unchanged. This validates mock mechanics; listening/speech, Safari, service,
Keychain, migration, and delivery remain the separate later gates above.
