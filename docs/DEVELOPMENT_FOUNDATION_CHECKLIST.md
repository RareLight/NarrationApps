# Development foundation implementation checklist

Updated October 16, 2026. This plan turns the organization/maintenance assessment
into bounded engineering stages. DF0 is retained; DF1/DF2/DF4–DF8 local engineering
and verification are complete as recorded below. DF3 official provider/action
review and remote activation remain externally controlled, not claimed complete.
It supplements the [product roadmap](IMPLEMENTATION_PLAN.md), not a request to
implement deferred product features. The
[original handoff](AGENT_HANDOFF_DEVELOPMENT_FOUNDATION.md) records execution scope.

## Starting checkpoint and evidence

The code baseline is root commit `7aa4740` plus the app revisions in
[DevelopmentBaseline.json](../DevelopmentBaseline.json). The following documentation
commit adds this plan and handoff; retain it. The root commit containing the
manifest identifies the root source revision, avoiding a circular self-SHA field.
Both app repositories are independently ignored by the root repository. The local
annotated tag `native-unification-2026-10-16` marks this checkpoint in each repo;
the root tag includes the handoff documentation commit. Keep these milestone tags
immutable when making later development commits.

- [x] DF0.1: Commit Libro features and native/layout cleanup separately.
- [x] DF0.2: Commit VoiceRelay features and native/layout cleanup separately.
- [x] DF0.3: Commit the shared/native processing and root workspace baseline.
- [x] DF0.4: Record compatible app commit IDs, clone URLs and verified toolchain.
- [x] DF0.5: Record operator confirmation that both current apps build and run.

The tested toolchain is Xcode 27.1 (27A9275), Swift 6.4 and macOS 27.0 SDK, arm64,
with a macOS 27.0 deployment target. Automated evidence is recorded in
[status](IMPLEMENTATION_STATUS.md); ignored raw reports are under
`.local/migration/root-layout/`. The latest gates passed 229 shared XCTest cases
(three existing opt-in skips), one shared Swift Testing case, two AppPresentation
cases, 18 LibroCore cases, 303 VoiceRelay core and 141 app cases. Combined Debug and
Release builds, all four ad-hoc signatures/Metal probes and both native engines
through each Release helper passed. Libro MP3 and VoiceRelay WAV synthetic outputs
passed readback with original repositories/previous build products and network
access denied. These are prior results, not instructions to rerun everything first.

The operator's build/run confirmation accepts basic launch/build smoke only.
[OPERATOR_VALIDATION.md](OPERATOR_VALIDATION.md) remains the sole detailed manual
checklist; do not infer completion of listening, document quality or live services.

## Rules for every stage

- Read root, package and relevant app AGENTS.md; preserve unrelated work.
- Use the current layout: root workspace/docs/scripts; packages under
  `swift-packages/`; independent `Libro/` and `VoiceRelay/` repositories.
- Keep the apps native Swift/Apple APIs with pinned native dependencies. No Python
  runtime, product CLI, FFmpeg/ffprobe dependency or new narration engine.
- Keep MLX helper-only, one worker per app, Libro interactive priority and
  VoiceRelay background yielding at safe boundaries. Do not interrupt GPU work.
- Preserve source prose/provenance, admission/checkpoint compatibility, dictionary
  storage, existing preferences, private assets, finished and published audio.
- Apply no normalization, leveling, gain, limiting or dynamic-range compression.
  Keep exact Float32 WAV behavior and the accepted podcast AAC 64 kbps/24 kHz profile.
- Use existing test/Apple tools first. Keep simple shell launchers when sufficient;
  structured native tooling should use Swift/Foundation. Avoid new tooling dependencies.
- Start with focused checks. Run broader gates for changed boundaries. Keep heavy
  builds and deadline-sensitive tests separate; serialize actual GPU generation.
- Keep caches/evidence ignored. Never copy build state, reset working caches or
  delete originals/user data as a convenience. Use disposable isolated fixtures.
- Commit logical work in its owning repository. Update the root compatibility
  manifest after validated app commits; the prior baseline remains in Git history.
  Never embed the root's own commit ID in a file that must define that same commit.
- Do not push, create remote repositories, enable paid CI, use signing accounts or
  operate live services without direct operator authorization. Prepare local
  reviewable configurations and mark external activation pending.

## DF1 — Reproducible setup and contributor workflow

- [x] Inventory existing root/package/app scripts and retain one owner for each
  operation. Reuse dependency preparation and workspace resolution already present.
- [x] Add a short root CONTRIBUTING.md: repository ownership, package boundaries,
  setup, focused checks, commit/manifest workflow, private-data rules and acceptance.
  Link app-specific guidance rather than duplicating its lifecycle/storage rules.
- [x] Define and implement a small read-only health check for app checkout presence,
  baseline revision/dirty-state reporting, Xcode selection, SDK/deployment support,
  arm64 execution, required tools and prepared dependency/Metal readiness.
- [x] Interpret DevelopmentBaseline.json with Foundation JSON/Codable and validate
  schema/paths/revisions. Branch names are informational; commit IDs identify a
  checkpoint. A dirty/mismatched app must produce useful diagnostics without checkout,
  reset, stash, migration or overwriting. Allow deliberate development divergence.
- [x] Provide one explicit setup entry point. Preparing pinned source dependencies
  may use the network; ordinary health checks must not. Clone/fetch missing app
  source only through an explicitly requested setup action using recorded remotes.
  Never auto-clone over an existing folder or auto-download speech/model assets.
- [x] Explain root cloning does not bring the two ignored app repositories or
  private settings/models. The recorded app commits currently exist locally;
  verify remote availability before promising a fresh clone can retrieve them.
- [x] Verify setup from a disposable sibling layout with its own generated state,
  not from the original archived directories. Do not duplicate large working caches.

Acceptance: existing working checkouts are unchanged by health checks; missing
repositories, unsupported toolchains, dirty state, malformed manifests and unavailable
revisions have tested actionable diagnostics. Setup is repeatable, preserves unexpected
edits, and does not install models or touch an account. Defer provider/credential
activation while completing local implementation.

DF1 initially passed 27 assertions; the expanded tooling now passes 72, using tiny
independent repositories in an owned disposable sibling, fake source acquisition
and diagnostic tools (no network/cache copy/models). `bash scripts/develop.sh health`
passes on the current native toolchain without changing app checkouts. Remote
checkpoint availability is explicitly unverified; setup refuses unavailable commits.

## DF2 — Tiered, repeatable validation entry points

- [x] Add explicit quick/full/native/release selections around existing checks;
  keep `bash scripts/check.sh` backward-compatible as the full isolated fixture gate.
- [x] Quick: layout/docs/configuration and affected package/app tests, with documented
  filtering. Do not label a filtered run a full-suite pass or silently skip failures.
- [x] Full: current AppPresentation/shared/LibroCore and VoiceRelay suites plus
  dependency preparation, shell/plist and packaging checks. Avoid duplicate runs.
- [x] Native: opt-in prepared-model offline helpers, frontend conformance,
  cancellation/reaping, admission arbitration and memory safety. Missing assets
  should clearly report unavailable/skip, not claim native acceptance passed.
- [x] Release: both Debug/Release workspace builds; individual app Archives for
  archive-specific behavior; embedded worker/Metal/notices/codec checks and signature
  verification. Keep Build Both Apps build-only. Preserve normal signing settings;
  separate ad-hoc engineering evidence from account/distribution acceptance.
- [x] Add Xcode test plans/dedicated test schemes where useful and actually supported.
  Verify each Test action and test target rather than assuming auto-generated package
  schemes can run tests. Reuse current tests; don't create duplicate test bodies.
- [x] Emit bounded ignored logs and a machine-readable summary with source revisions,
  dirty state, toolchain, tier, outcomes/skips and evidence paths. Distinguish tests,
  packaged runs and operator acceptance. Default diagnostics must omit private text.
- [x] Test command argument handling, failure propagation, selective execution and
  summary accuracy with fake runners/disposable fixtures. No real app launches.

Acceptance: a developer can choose the narrowest suitable gate; full validation
preserves existing coverage; failures and unavailable native gates cannot appear
green. Xcode plans, if added, must work in the root workspace.

DF2 initial integration evidence: quick/static/tooling and the full gate pass. That
run is `.local/validation/full-0B80037E-8A69-4A74-B131-5439D799CD6E/summary.json`.
It retains 229 shared XCTest (three explicit opt-in skips), one shared Swift
Testing, two presentation, 18 LibroCore, 303 VoiceRelay core and 141 app cases.
Two earlier harness attempts failed on nested sandbox/bookmark-entitlement
behavior; product assertions were not weakened. Existing Xcode Test actions were
verified with DF5: LibroCoreTests passed five ProjectResources tests and VoiceRelay
passed its selected unique-reference test. `.xcresult` summaries confirm five and
one tests, not empty Test actions. No duplicate plans/test bodies were added.

The actual release tier passed both configurations, both individual Archives and
all six bundle/signature/Metal/resource checks:
`.local/validation/release-E0374846-76BD-4E1F-811E-5E8C6002BCB5/summary.json`.
An initial verifier assumption about VoiceRelay's executable name was corrected to
read CFBundleExecutable. The configured native tier also passed using the existing
isolated prepared workspace, with both helpers' frontend/mixed jobs, safety
fixtures and arbitration/cancellation:
`.local/validation/native-FBBDFEBF-8A74-4B4A-AD4E-76DE4D44EDAB/summary.json`.
Its no-argument invocation separately returned unavailable/exit 3 as intended.

## DF3 — Continuous integration readiness

- [ ] Determine a suitable provider and current macOS/arm64/Xcode availability using
  official documentation. The root repository has no configured remote; do not
  invent its URL or assume hosted runners support macOS 27 frameworks or GPU/model work.
- [x] Prepare source-controlled CI definitions that invoke DF2 entry points rather
  than reimplementing their logic. Check out app revisions from the manifest.
- [x] Run fast checks for ordinary changes and broader fixtures/builds for shared
  API, package/dependency, worker, persistence or project changes. Offer explicit
  manual full/release runs; do not add a recurring app automation for CI.
- [x] Separate source dependency acquisition from offline tests. Use no live Safari,
  Keychain, WebDAV, private corpus, production feed or automatic model downloads.
- [x] Keep heavyweight native inference on a compatible, explicitly enabled machine;
  serialize GPU work and avoid overlapping timing-sensitive suites with heavy builds.
- [x] If caching is used, key it to toolchain/SDK/architecture/paths/locks/patches;
  never transplant DerivedData or SwiftPM workspace state into unrelated checkouts.
- [x] Validate workflow syntax and local commands. Report provider activation,
  credentials, billing or hardware access as operator steps until authorized.

Acceptance: local CI-equivalent gates are reproducible. Workflow configuration is
reviewable; actual remote CI success is claimed only after a real authorized run.
Unavailable external activation must not prevent independent later local stages.

DF3: an inactive `.devin/ci/github-actions.yml` template targets a dedicated
self-hosted arm64 machine, not an assumed hosted image. YAML parsed locally;
the local full equivalent passes. Current official provider/action review awaits
network permission. Root/app remote availability, credentials, runner enrollment,
cost approval, activation and actual remote success remain external. No cache,
native-model job, untrusted-PR self-hosted execution or scheduled app automation.

## DF4 — Canonical regression corpus and architecture contracts

- [x] Inventory existing shared/app fixtures and tests first; create a small catalog
  referencing them by purpose. Move/delete duplicates only after replacement coverage
  passes. Preserve licenses and the distinction between authored and generated data.
- [x] Cover plaintext/legacy encodings/override, Markdown, rich text/HTML, native PDF,
  OCR, DRM-free EPUB, images/caption dedup, authored navigation and cover metadata.
- [x] Retain expected spoken text, omissions and source mappings for normalization,
  pronunciation overrides, letter A, punctuation, quantities, regional G2P and
  boundary/subtoken failures. Do not silently accept regenerated expected values.
- [x] Keep important contracts mandatory: no prose truncation, supported phoneme
  vocabulary/token limits, private helper-only MLX, independent AppPresentation,
  source-mapped omissions, original audio levels and atomic final-output preservation.
- [x] Maintain compatibility fixtures for worker messages/prepared plans, retained
  metadata/settings/library records and pronunciation persistence. Change versions
  only for a justified contract change, with old/new tests.
- [x] Reuse bounded synthetic PDF/Markdown mixed jobs for memory/cancellation tests.
  Separate host/helper measurements, worker cleanup and hard safety-limit assertions
  from throughput trends. Performance trends need a fixed-machine baseline and
  recorded hardware/toolchain; avoid fragile elapsed-time thresholds in generic CI.
- [x] Keep real listening, OCR/caption quality and private-document acceptance in the
  existing operator checklist. Do not add private books or user recordings to Git.

Acceptance: fixtures have clear ownership and reproducible expectations; existing
coverage remains or improves. Run affected suites and offline native gates when
acoustic/preparation/IPC/audio behavior is touched; no new engine policy is authorized.

DF4: [corpus inventory](REGRESSION_CORPUS.md) names existing canonical expectations;
no duplicates/golden data were removed or regenerated. Parsed architecture gates
enforce independent presentation, transitive helper-only MLX and six owned locks
without forcing unrelated dependency graphs identical. Full fixtures pass above;
no acoustic/preparation/IPC/audio behavior was changed by this stage.

## DF5 — Focused app-file decomposition

- [x] Split Libro's approximately 1,800-line LibroApp.swift along existing boundaries:
  app/delegate startup, intake/batch state, queue/progress, document preview,
  Settings and speech-setup UI. Keep app workflow here and common capability shared.
- [x] Split VoiceRelay's approximately 1,700-line application-model file into coherent
  existing responsibilities, such as lifecycle/health, owned Sync tasks, setup and
  coordinator event projection. Inspect current presentation files before moving code.
- [x] Review Delivery.swift only for a clearly useful small extraction; do not combine
  lifecycle/storage/publishing redesign with file organization. Avoid speculative
  new services, protocols, coordinators or additional packages.
- [x] Preserve actor isolation, access control, cancellation/join ownership, event
  ordering, persistence keys, timing, inert previews and user-visible behavior.
- [x] Make each extraction independently reviewable. Add focused regressions where a
  seam changes. Update Xcode's explicit source references; run VoiceRelay's
  `xcodeProjectAppSourcesUseUniqueBuildFileReferences` after project.pbxproj edits.
- [x] Verify SwiftPM/app suites and Debug/Release Xcode builds after relevant moves.
  Recheck archive/packaged resources if packaging or worker wiring changes.

Acceptance: responsibilities are easier to locate and test; no generic abstraction
or behavior change is introduced merely to reduce line counts. New UI acceptance
is operator-owned and should be requested only for changed flows or a final smoke pass.

DF5 keeps method bodies, main-actor isolation and task/join owners unchanged, with
only necessary module-local extension seams (no new public API). Delivery was
reviewed and left unchanged: DeliveryRead already separates read-side concerns.
VoiceRelay's unique-reference regression and four affected app tests pass; both
app builds/Archives and real Xcode Test actions pass above. The new Libro project
test initially mistook nested target-attribute keys for object definitions; it
now scopes object definitions and cross-checks the parsed object count.
The full 141-case VoiceRelay app suite and all 19 LibroCore cases pass after the
extractions, including the new source-reference contract. Owning source commits
are recorded in the manifest; formatting stays in separate subsequent commits.

## DF6 — Formatting and documentation lifecycle

- [x] Adopt a modest explicit swift-format configuration using the installed
  `swift format` tool; avoid introducing a formatter dependency by default.
- [x] Apply the same rules deliberately across the three repositories. Exclude
  dependencies, patches, generated output, license notices and golden fixture data.
  Keep formatting-only commits separate from logic changes and avoid a wholesale
  reformat that obscures DF5 review. Document baseline/graduated enforcement.
- [x] Keep one architecture, product roadmap, engineering checklist, current status
  and operator checklist. Summarize repeated completed-stage evidence in status;
  retain accepted decisions/limitations and useful provenance pointers.
- [x] Resolve stale links/labels and contradictory historical counts/acceptance
  statements. Keep essential API/model/license records and original notices intact.
- [x] Keep agent instructions short and consistent with contributor guidance; app
  instructions may retain their domain-specific invariants. Don't rewrite all
  historical documentation merely to match current filesystem paths.
- [x] Ensure fixtures and docs remain checked after cleanup. Git history preserves
  retired plans; ignored raw evidence may be absent on a fresh checkout and must
  not be a hidden setup dependency.

Acceptance: formatting is deterministic and scoped; setup/status facts have one
maintained owner. Documentation checks pass in the root, package and both apps.

DF6's identical native formatter profiles are tracked in `.devin/` in all owners.
Strict lint passes the graduated baseline: five tooling files and one small
extracted file per app. Formatting-only commits are separate from decomposition.
VoiceRelay's existing private `.devin/` ignore policy remains unchanged; only the
two nonsecret style files were explicitly tracked. Quick/static includes scoped
lint, architecture and all four documentation owners. Repeated relocation prose,
stale current paths/count labels and handoff labels were corrected without
rewriting historical plans or original dependency notices.

## DF7 — Dependency and release maintenance policy

- [x] Document one dependency-update procedure: exact upstream revision/license,
  current patch inventory, upstream fix comparison, reproducible preparation and
  the smallest adequate validation matrix. Don't update pins merely for cleanup.
- [x] Retire patches only after proving the upstream replacement preserves the
  intended behavior. Repeat API/behavior/native checks for touched engine changes.
- [x] Define ownership for app/package/workspace resolution files. Allow deliberate
  independent consumer graphs; detect incompatible drift without blindly making all
  lockfiles identical. Record tested composition in the root manifest.
- [x] Document commit/release naming and compatibility expectations for shared APIs,
  worker protocols, acoustic identities and persisted data. Preserve version strings
  that intentionally support old checkpoints or cross-app admission.
- [x] Define a release evidence manifest containing all three actual commit IDs,
  dirty state, toolchain, dependency/patch/resource fingerprints, artifact digests,
  signing class and completed/unavailable gates. Generated reports avoid the root
  self-SHA problem and belong in ignored output unless deliberately published.
- [x] Consolidate packaging/resource/notices/signature checks into the release tier.
  Document human account/notarization, clean-Mac, installer/player and live-service
  gates without executing them or changing personal-team settings.
- [x] Keep remote package publication/export/registry strategy documented as future
  distribution work. The parent repository has no root Package.swift and patched
  ignored source dependencies still require preparation; a bare repository URL is
  not yet a ready-to-consume SwiftNarration release. No publication is requested.

Acceptance: a future update/release has a repeatable checklist and clear ownership;
current pins, models, audio policy, signing configuration and public outputs remain
unchanged unless a separately justified change is tested and recorded.

DF7's canonical procedure is in
[dependency maintenance](DEPENDENCIES.md#maintenance-procedure-and-ownership).
Current pins/patches/models/version identifiers are unchanged. The real release
report records source/dirty state, toolchain, dependency/patch/resource fingerprints
and per-bundle artifact digests. Ad-hoc signing remains engineering evidence only;
no account, remote or publication was operated.

## DF8 — Final engineering handoff

- [x] Run the affected tiers, plus final root full fixtures and both app builds for
  changed source/project boundaries. Run native/archive checks where relevant.
- [x] Inspect source diffs, private-data exclusions and all three repository statuses.
  Commit logical changes in their owners, update app revisions in the root manifest
  after the corresponding validated commits, and verify compatibility metadata.
- [x] Update this checklist and status with actual results, unresolved failures and
  externally blocked CI/distribution actions. Never mark a stage complete because
  its configuration file exists or because a test was skipped.
- [x] Hand back concise operator testing limited to affected flows and remaining
  acceptance IDs. Keep the existing product checklist authoritative.

DF8 final source composition was clean at root `20240ff`, Libro `ad758a6` and
VoiceRelay `9e34c49` (full SHAs are in the generated reports/manifest). The final
root full gate passed 229 shared XCTest with three existing opt-in skips, one
shared Swift Testing, two AppPresentation, 19 LibroCore, 303 VoiceRelay core and
141 app cases, plus 72 tooling assertions, static/format/architecture/lock/docs,
preparation/number/plist and isolated packaging checks.

Final reports:
- `.local/validation/full-35D635AF-2230-456B-93A8-E7B4A15EC192/summary.json`
- `.local/validation/release-9DA36E05-4ADA-4E95-B7F7-0CD528309724/summary.json`
- `.local/validation/native-FBBDFEBF-8A74-4B4A-AD4E-76DE4D44EDAB/summary.json`

Final release passed both workspace configurations, both individual Archives and
six actual bundle/signature/Metal/resource checks, including Libro's packaged
codec load/required symbols. All six signatures are ad-hoc engineering evidence.
The final Release workers are byte-identical to the native-tested workers;
`native-worker-continuity.json` beside the final release summary records their
SHA-256 values and native report linkage. Native passed 68 frontend records per
helper (two expected rejections each), four mixed-document outputs per helper,
memory/safety fixtures and admission/cancellation/reaping.

All three source diffs/statuses, private exclusions, checkpoint ancestry and
unchanged annotated tag targets were reviewed. Independent histories/remotes,
pins/patches/models, preferences, notices, audio policy and recordings are preserved.
No source/build/test failures remain unresolved. Official CI review/activation,
remote commit availability and distribution accounts remain external. The only
foundation-specific operator request is the limited final smoke already described
in [operator validation](OPERATOR_VALIDATION.md#before-starting): L01/L02/L05/L12/L18
and V01/V02/V10 using an authorized disposable setup. Existing quality/listening,
private-document/B06, protected/live-service and distribution cases remain open.

Existing product acceptance, B06 and future product features remain on the
[product roadmap](IMPLEMENTATION_PLAN.md). This engineering plan does not authorize
complex-layout rewrites, chaptered audio, new pronunciation policies or live publication.

## Reference tools

Use current primary documentation when implementing version-sensitive tooling:
[Apple test plans](https://developer.apple.com/documentation/xcode/organizing-tests-to-improve-feedback)
and [official swift-format](https://github.com/swiftlang/swift-format).
