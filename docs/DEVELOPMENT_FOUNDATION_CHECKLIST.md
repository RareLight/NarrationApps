# Development foundation completion record

Current-state review: October 21, 2026. The DF stages below were implemented during
the October 16 foundation work and updated for the October 20 monorepo migration.
This is a completion record, not an instruction to restart those stages. Use
[CONTRIBUTING.md](../CONTRIBUTING.md) and [DEVELOPMENT.md](DEVELOPMENT.md) for current
commands, [status](IMPLEMENTATION_STATUS.md) for evidence and the
[roadmap](IMPLEMENTATION_PLAN.md) for remaining work.

## Stage completion and current equivalents

| Stage | Engineering result | Current source of truth |
| --- | --- | --- |
| DF0 — Compatible source checkpoint | Complete; superseded separate app pins with one containing monorepo commit | DevelopmentBaseline.json schema 2; migration record |
| DF1 — Setup/contributor workflow | Complete; offline health and explicit pinned preparation/resolution | CONTRIBUTING; scripts/development/Baseline.swift and Setup.swift |
| DF2 — Tiered validation | Complete; quick/full/native/release, filtered runs, bounded logs and machine summaries | DEVELOPMENT; scripts/development/Validation.swift |
| DF3 — CI readiness | Inactive template and local selectors complete; provider/action review and remote execution remain pending | CI.md; .devin/ci/github-actions.yml |
| DF4 — Regression ownership/contracts | Complete; shared/app synthetic fixtures and transitive GUI/helper/lock checks | REGRESSION_CORPUS; scripts/check-contracts.swift |
| DF5 — Focused source organization | Complete; extracted views/extensions retain original state and task owners | ARCHITECTURE; app architecture/instructions |
| DF6 — Formatting/document lifecycle | Complete; explicit per-scope allowlists and current-document ownership | DEVELOPMENT; DOCUMENTATION.md |
| DF7 — Dependency/release maintenance | Complete policy and evidence tooling; public distribution is a separate gate | DEPENDENCIES; release checklist |
| DF8 — Engineering handoff | Completed local gates; operator acceptance stays separate | IMPLEMENTATION_STATUS; OPERATOR_VALIDATION |

The monorepo includes both apps. Setup no longer clones them or checks separate
commit pins. Strict health requires a clean root tree and tracked app sources.
Validation summary schema 2 records one root revision; owned package lockfiles
remain separate because their build graphs are separate.

## Source organization and invariants retained

Libro keeps scene/delegate ownership in LibroApp and workflow/task state in
IntakeModel, with separate intake, queue, preview, narration, Settings and speech
setup views. VoiceRelay keeps stored AppModel state/lifecycle in VoiceRelayApp,
with Sync, speech-setup, health and event extensions. Common UI belongs to
AppPresentation, NarrationUI and PronunciationUI. These are source organization
changes, not new public APIs or persistence ownership.

The foundation retains native Swift/Apple APIs, pinned dependencies, helper-only
MLX, one worker per app and safe Libro priority. Original text/mappings, settings,
completed audio, private inputs and live libraries are preserved. Audio is never
normalized, levelled, limited or given gain. No Python runtime, product CLI,
FFmpeg dependency, live migration or model installation was introduced.

## Verification and evidence

The original October 16 gates are dated historical results. Subsequent feature
work changes suite totals; do not treat old counts as today's expected inventory.
The October 20 monorepo run passes the full isolated gate, both workspace build
configurations and all four complete bundle audits, recorded in
[MONOREPO_MIGRATION.md](MONOREPO_MIGRATION.md#validation).
Development tooling now verifies 78 assertions for schema/path validation,
monorepo source ownership, strict dirty-root behavior, setup preservation, selection,
failure evidence and CI path classification using isolated local fixtures.

The operator's October 16 build/run confirmation accepts basic launch smoke only.
GUI, real-document/OCR quality, listening, Keychain/WebDAV, restore and signing/
distribution checks remain in [OPERATOR_VALIDATION.md](OPERATOR_VALIDATION.md).
The documentation review does not rerun or accept those tests.

## Historical source references

The former three-repository layout used app commit pins and an annotated
`native-unification-2026-10-16` checkpoint. Those references are historical and may
exist only in the private original Git metadata after privacy filtering. Do not
reset current source, restore nested Git directories or fetch old application
repositories to follow the former setup. The
[original request](AGENT_HANDOFF_DEVELOPMENT_FOUNDATION.md) is retained as provenance;
its imperative text does not authorize new work.

## Remaining external work

The monorepo's initial manual source publication is complete in the recorded
`origin/main` state. CI activation, runner provisioning, account/cost approval,
real remote-run evidence and public application/package releases remain separate.
Do not equate source publication with a notarized application release or an active
CI job. Complete only the remaining work explicitly authorized for the current task.
