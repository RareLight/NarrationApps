# Libro and shared-component review fixes

October 27, 2026. This plan covers the five substantive findings in the whole-app
review and the related import-scanner ownership improvement. The completed
[VoiceRelay fixes](VOICERELAY_REVIEW_FIX_PLAN.md) remain intact. Current contracts
and validation are recorded in [architecture](ARCHITECTURE.md),
[development gates](DEVELOPMENT.md) and [implementation status](IMPLEMENTATION_STATUS.md).

## 1. Protect sources and outputs

- Reject output destinations inside selected directory inputs, including unpacked
  EPUB resources and canonical aliases, before replacement approval. Preserve
  existing regular-source, hardlink and destination-collision safeguards.
- Propagate explicit replacement approval to atomic publication. Use exclusive
  rename semantics for unapproved targets so a file arriving after revalidation
  survives. Keep intended replacement of owned scratch/direct-API outputs compatible.
- Regressions: nested existing/new EPUB resources, symlink aliases, late arrivals
  after publication authorization, explicit approved replacement and unchanged
  source bytes through the production model-free coordinator.

## 2. Preserve preferences and own intake work

- Persist validated model/voice/speed in Libro-owned preferences. Restore supported
  saved choices; handle absent, legacy and unreadable records without silently
  rewriting stored data. Captured running batches stay immutable.
- Own file-drop resolution and provider progress, invalidate stale completions,
  and cancel/join or safely detach unresponsive provider callbacks. Clear, Cancel,
  replacement imports and Quit cannot reintroduce dropped work later.
- Join replaced scanner work before starting its replacement; shutdown joins the
  complete owned chain. Preserve source scopes and UI revision checks.
- Regressions: isolated settings round trips/invalid data, gated provider completion,
  double/late callbacks, Clear/Cancel/shutdown, scanner replacement and cancellation.

## 3. Avoid repeated whole-batch planning

- Build source-protection/collision information once per batch and revalidate the
  current document/target at the existing safety boundaries. Preserve destination
  binding, source protection, alias and late-file checks.
- Replace quadratic prefix collision scans with sorted or indexed checks. Keep
  original processing order, captured membership and cancellation behavior.
- Regressions: sibling/prefix/case/canonical collisions, moved/symlinked targets,
  queued reorder/pause/skip/stop, and a synthetic planner comparison. Report measured
  checks separately from extrapolated full-batch performance.

## 4. Validate and document

- Coordinate focused synthetic checks first, followed by the full project fixture
  gate. Do not overlap timing-sensitive checks and heavyweight builds.
- Build Debug and Release in a new ignored directory; audit both app bundles in
  both configurations. Do not copy build caches or replace an operator's app.
- Update current user/developer documentation and the completion record with actual
  evidence. Preserve VoiceRelay changes, model assets, real preferences, completed
  recordings, original documents and private data. Do not commit or push.
- GUI/Canvas, real documents, listening, signing accounts and provider-specific
  acceptance remain in the [operator checklist](OPERATOR_VALIDATION.md).

## Completion record

Implementation of all five findings and scanner ownership is complete. The full
fixture gate passed on October 27, 2026, including 38 LibroCore tests, 328 VoiceRelay
core tests, 166 VoiceRelay app tests and the shared/static/packaging suites. Focused
coverage includes eight planner tests, 35 scheduling tests, five atomic-writer
tests, cancelled/nonresponding providers, late/double callbacks, invalid isolated
preferences and joined scanner shutdown. Existing private-document/native audio
opt-ins remain skips. The sandboxed scheduling attempt was not a pass; its
isolated rerun with macOS file coordination available passed.

Fixture evidence: `.local/validation/full-C362DC1E-6FB1-4168-B1C5-143E6D4F0352/summary.json`.
Focused logs are under `.local/libro-fixes/`. The 1,200-input synthetic Debug check
measured 0.277 seconds for one complete plan and 0.138 seconds total for three
current-target validations. This is one local measurement, not a full-batch
narration benchmark. Live source/inode protection still requires linear metadata
checks at each boundary; the change removes repeated full output planning and
quadratic prefix comparisons without assuming files remain unchanged.

Debug and Release workspace builds pass, as do all four bundle audits (Libro and
VoiceRelay in each configuration). Ad-hoc engineering products are under
`.build/LibroReviewFixes-20261027/Build/Products/{Debug,Release}/`. Reports in
`.local/libro-fixes/` verify arm64, helper-only MLX, resources/notices/samples,
codec linkage, signatures and offline Metal readiness. These are packaging checks,
not speech or distribution-signing acceptance. Two final alias regressions pass, including late hardlinks between approved
outputs. Final static/layout/contracts/formatting/docs/plist checks also pass.
Their evidence is recorded in `.local/libro-fixes/summary.json`. Nested sandbox
restrictions on manifest inspection were resolved by the authorized static rerun. GUI,
protected-file providers, real documents, listening and signing accounts remain
operator-owned. No installed app, model asset, private document, completed audio,
real preference domain, commit or remote has been changed by this validation.
