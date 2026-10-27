# VoiceRelay whole-app review fixes

Implementation plan, October 26, 2026. This work addresses the eight VoiceRelay
findings from the whole-app review. The standalone benchmark and the subsequent
Libro/shared-component review are separate scopes. Current behavior and evidence
belong in [architecture](../VoiceRelay/docs/ARCHITECTURE.md) and
[implementation status](IMPLEMENTATION_STATUS.md).

## Stage 1 — Safe publishing and retirement

- Bind retirement intent to the recorded destination. Refuse old-destination or
  unowned paths at execution, including previously recorded unsafe intent. Preserve
  old server copies and feed-before-delete ordering.
- Cancel an active delivery drain when Publishing is disabled. Retain interrupted
  work for explicit re-enablement; do not schedule disabled follow-up writes.
- Update only owners of a deleted object. Avoid rewriting every retired episode
  for each media/sidecar deletion, retaining durable crash-recovery markers.
- Keep transcript-only failed removals visible after successful media deletion;
  expose the owning episode's retry error without reading or mutating live services.
- Regressions: destination switch followed by retirement, stale deletion intent,
  current-destination retirement, disablement during a suspended request,
  cancellation/re-enable, and unchanged unrelated retired records.

## Stage 2 — Source identity and titles

- Detect removed source URLs independently of stable Safari entry IDs. Retargeted
  entries invalidate old queued work/cache through the existing removal path.
  App callbacks stop/join obsolete speech; remaining duplicate references rebind
  their existing queue jobs and release the retargeted ID for replacement admission.
  Automatic failure suppression follows URLs, including during active speech.
- Publish original article URL/host for archive recovery; retain replay URLs only
  in private provenance. Preserve ordinary canonical-link behavior.
- Preserve descriptive HTML titles matching URL slugs; keep weak PDF filename
  recovery, conservative fallback and optional generation behavior.
- Regressions: same-ID URL replacement, duplicate source URLs, archive source
  attribution with absent/rewritten canonicals, HTML headline/slug match and PDF
  filename recovery.

## Stage 3 — Captured audio policy and transcript mapping

- Apply each episode's captured pause policy while reusing compatible model
  sessions. Handle compatible chunk checkpoints without changing samples, model
  math or already completed recordings.
- Refresh owned transcript references when only the public mapping changes.
  Preserve exact-byte upload/readback, independent backoff and external references.
- Regressions: mixed zero/nonzero gaps in one drain, checkpoint assembly policy,
  public-URL-only edits, metadata-only RSS refresh and transcript failure recovery.

## Stage 4 — Integration and evidence

- Run the narrow relevant synthetic regressions first, using fake transports,
  credentials, disposable stores and the model-free helper.
- Run the full project fixture gate serially. Build Debug and Release in a new
  ignored DerivedData directory and audit both app bundles in both configurations.
- Update current user/developer documentation and the status record with actual
  results and evidence paths. Do not commit, push, install or launch candidates.
- GUI, listening, protected Safari, real Keychain/WebDAV and player behavior remain
  in [operator validation](OPERATOR_VALIDATION.md). A passing build does not close
  those checks.

## Completion record

Stages 1–4 are complete. Final October 27 validation covers all eight findings,
app-level source-retarget cancellation/reassociation and transcript-only retirement
visibility, with the full fixture gate, isolated Debug/Release builds and four
bundle audits passing. The final evidence locations and
remaining manual boundaries are recorded in [implementation status](IMPLEMENTATION_STATUS.md).
The final full fixture run is
`.local/validation/full-0F216836-5CB5-47F8-8A04-E9E1113F9997/`, including 328
VoiceRelay core tests, 166 app tests and the shared/Libro suites. Existing opt-in
private/native tests remain skips. Engineering candidates and bundle audit logs
use `.build/VoiceRelayReviewFixes-20261026/` and `.local/review-fixes/` respectively.
