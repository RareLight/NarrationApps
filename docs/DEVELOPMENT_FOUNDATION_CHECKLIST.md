# Development foundation implementation checklist

Updated October 16, 2026. This plan turns the organization/maintenance assessment
into bounded engineering stages. DF0/DF1/DF4 are complete; DF2/DF3 local tooling
is implemented with Xcode Test-action verification and external activation tracked
below. DF5–DF8 are in progress.
It supplements the [product roadmap](IMPLEMENTATION_PLAN.md), not a request to
implement deferred product features. The ready-to-paste
[agent handoff](AGENT_HANDOFF_DEVELOPMENT_FOUNDATION.md) defines execution scope.

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

DF1 evidence: `bash scripts/test-development.sh` passes 27 assertions using tiny
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
- [ ] Add Xcode test plans/dedicated test schemes where useful and actually supported.
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

DF2 local evidence: quick/static/tooling and the final full gate pass. The full
run is `.local/validation/full-0B80037E-8A69-4A74-B131-5439D799CD6E/summary.json`.
It retains 229 shared XCTest (three explicit opt-in skips), one shared Swift
Testing, two presentation, 18 LibroCore, 303 VoiceRelay core and 141 app cases.
Two earlier harness attempts failed on nested sandbox/bookmark-entitlement
behavior; product assertions were not weakened. Existing Xcode Test actions are
being exercised with DF5 builds; no duplicate test bodies/plans were introduced.
Native/release configuration is not yet a claim those tiers were run.

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

- [ ] Split Libro's approximately 1,800-line LibroApp.swift along existing boundaries:
  app/delegate startup, intake/batch state, queue/progress, document preview,
  Settings and speech-setup UI. Keep app workflow here and common capability shared.
- [ ] Split VoiceRelay's approximately 1,700-line application-model file into coherent
  existing responsibilities, such as lifecycle/health, owned Sync tasks, setup and
  coordinator event projection. Inspect current presentation files before moving code.
- [ ] Review Delivery.swift only for a clearly useful small extraction; do not combine
  lifecycle/storage/publishing redesign with file organization. Avoid speculative
  new services, protocols, coordinators or additional packages.
- [ ] Preserve actor isolation, access control, cancellation/join ownership, event
  ordering, persistence keys, timing, inert previews and user-visible behavior.
- [ ] Make each extraction independently reviewable. Add focused regressions where a
  seam changes. Update Xcode's explicit source references; run VoiceRelay's
  `xcodeProjectAppSourcesUseUniqueBuildFileReferences` after project.pbxproj edits.
- [ ] Verify SwiftPM/app suites and Debug/Release Xcode builds after relevant moves.
  Recheck archive/packaged resources if packaging or worker wiring changes.

Acceptance: responsibilities are easier to locate and test; no generic abstraction
or behavior change is introduced merely to reduce line counts. New UI acceptance
is operator-owned and should be requested only for changed flows or a final smoke pass.

## DF6 — Formatting and documentation lifecycle

- [ ] Adopt a modest explicit swift-format configuration using the installed
  `swift format` tool; avoid introducing a formatter dependency by default.
- [ ] Apply the same rules deliberately across the three repositories. Exclude
  dependencies, patches, generated output, license notices and golden fixture data.
  Keep formatting-only commits separate from logic changes and avoid a wholesale
  reformat that obscures DF5 review. Document baseline/graduated enforcement.
- [ ] Keep one architecture, product roadmap, engineering checklist, current status
  and operator checklist. Summarize repeated completed-stage evidence in status;
  retain accepted decisions/limitations and useful provenance pointers.
- [ ] Resolve stale links/labels and contradictory historical counts/acceptance
  statements. Keep essential API/model/license records and original notices intact.
- [ ] Keep agent instructions short and consistent with contributor guidance; app
  instructions may retain their domain-specific invariants. Don't rewrite all
  historical documentation merely to match current filesystem paths.
- [ ] Ensure fixtures and docs remain checked after cleanup. Git history preserves
  retired plans; ignored raw evidence may be absent on a fresh checkout and must
  not be a hidden setup dependency.

Acceptance: formatting is deterministic and scoped; setup/status facts have one
maintained owner. Documentation checks pass in the root, package and both apps.

## DF7 — Dependency and release maintenance policy

- [ ] Document one dependency-update procedure: exact upstream revision/license,
  current patch inventory, upstream fix comparison, reproducible preparation and
  the smallest adequate validation matrix. Don't update pins merely for cleanup.
- [ ] Retire patches only after proving the upstream replacement preserves the
  intended behavior. Repeat API/behavior/native checks for touched engine changes.
- [ ] Define ownership for app/package/workspace resolution files. Allow deliberate
  independent consumer graphs; detect incompatible drift without blindly making all
  lockfiles identical. Record tested composition in the root manifest.
- [ ] Document commit/release naming and compatibility expectations for shared APIs,
  worker protocols, acoustic identities and persisted data. Preserve version strings
  that intentionally support old checkpoints or cross-app admission.
- [ ] Define a release evidence manifest containing all three actual commit IDs,
  dirty state, toolchain, dependency/patch/resource fingerprints, artifact digests,
  signing class and completed/unavailable gates. Generated reports avoid the root
  self-SHA problem and belong in ignored output unless deliberately published.
- [ ] Consolidate packaging/resource/notices/signature checks into the release tier.
  Document human account/notarization, clean-Mac, installer/player and live-service
  gates without executing them or changing personal-team settings.
- [ ] Keep remote package publication/export/registry strategy documented as future
  distribution work. The parent repository has no root Package.swift and patched
  ignored source dependencies still require preparation; a bare repository URL is
  not yet a ready-to-consume SwiftNarration release. No publication is requested.

Acceptance: a future update/release has a repeatable checklist and clear ownership;
current pins, models, audio policy, signing configuration and public outputs remain
unchanged unless a separately justified change is tested and recorded.

## DF8 — Final engineering handoff

- [ ] Run the affected tiers, plus final root full fixtures and both app builds for
  changed source/project boundaries. Run native/archive checks where relevant.
- [ ] Inspect source diffs, private-data exclusions and all three repository statuses.
  Commit logical changes in their owners, update app revisions in the root manifest
  after the corresponding validated commits, and verify compatibility metadata.
- [ ] Update this checklist and status with actual results, unresolved failures and
  externally blocked CI/distribution actions. Never mark a stage complete because
  its configuration file exists or because a test was skipped.
- [ ] Hand back concise operator testing limited to affected flows and remaining
  acceptance IDs. Keep the existing product checklist authoritative.

Existing product acceptance, B06 and future product features remain on the
[product roadmap](IMPLEMENTATION_PLAN.md). This engineering plan does not authorize
complex-layout rewrites, chaptered audio, new pronunciation policies or live publication.

## Reference tools

Use current primary documentation when implementing version-sensitive tooling:
[Apple test plans](https://developer.apple.com/documentation/xcode/organizing-tests-to-improve-feedback)
and [official swift-format](https://github.com/swiftlang/swift-format).
