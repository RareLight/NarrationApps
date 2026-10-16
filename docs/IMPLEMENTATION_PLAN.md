# Current implementation and remaining work

Updated October 15, 2026. Native unification and Kokoro LF0–LF7 implementation were
authorized and their automated integration gates are complete. This is the current
roadmap; completed stages and their evidence are recorded in
[implementation status](IMPLEMENTATION_STATUS.md).

## Implemented baseline

Both apps consume SwiftNarration and the independent AppPresentation package.
Shared intake/OCR/image handling, pronunciation editing, native speech preparation,
supervised helpers, audio and common Settings controls are implemented. App-owned
Libro batches and VoiceRelay discovery/SQLite/Publishing remain separate.

Kokoro uses the operator-selected Heart/1.0× pause profile. All 29 samples were
regenerated through that pipeline with the selected common phrase. One worker per
app, safe Libro priority, no normalization/volume leveling, and finished-recording
preservation remain invariants. Soprano retains its text frontend. Details are in
[architecture](ARCHITECTURE.md) and [current validation status](IMPLEMENTATION_STATUS.md).

## Latest implemented feature sequence

The [cover art and document navigation plan](COVER_ART_AND_NAVIGATION_PLAN.md)
records the implemented increment: Libro embedded export covers, VoiceRelay
show artwork, authored outlines, local heading deduplication, explicit narration
controls and bounded spoken-form corrections. CA0–CA3 and DN1–DN3 engineering is complete;
operator cover/navigation/narration checks L17–L19 and V17–V19 remain open. SF1
retains the accepted pronunciation baseline without speculative new rules.

## Development foundation

The coordinated source checkpoint is complete. The detailed
[development foundation checklist](DEVELOPMENT_FOUNDATION_CHECKLIST.md) covers
reproducible setup, tiered validation/CI readiness, regression contracts, focused
app-file cleanup, formatting/documentation and dependency/release maintenance.
Use its [agent handoff](AGENT_HANDOFF_DEVELOPMENT_FOUNDATION.md) for that work.
These local engineering stages can proceed independently of outstanding product
quality/service acceptance; deferred product features are not added to their scope.

## Next work

1. Complete the [consolidated operator checklist](OPERATOR_VALIDATION.md): GUI,
   actual private PDF/Markdown freeze reproduction, final samples/narration,
   OCR/caption quality, lifecycle and cross-app waiting. Live VoiceRelay Safari,
   Keychain, WebDAV, podcast playback and test-library restore remain operator-owned.
2. Validate Delivery B of the [text-processing checklist](TEXT_PROCESSING_IMPROVEMENT_PLAN.md)
   through B06: paragraph/source fidelity, conservative PDF margin/continuation
   decisions, progress/cancellation and matched listening. Delivery A listening,
   including letter A, is operator accepted. TP4–TP7 engineering is implemented;
   complex layout, chaptered audio, caption scheduling and further citation/homograph
   changes remain separate future scope; the implemented outline/control increment
   is recorded above.
3. Resolve reported app-specific acceptance failures in their owning repository;
   keep shared bugs/tests canonical in the packages. Add focused regressions and
   repeat affected gates before the next operator candidate.
4. When distribution is planned, complete account/entitlement, clean-Mac and
   notarization/installer acceptance. Local ad-hoc artifacts do not establish those.
5. Before publishing shared packages remotely, establish repository/tag/export or
   registry strategy and replace reliance on ignored prepared local dependency
   paths with a release-ready source strategy. See [package management](PACKAGE_BOUNDARIES.md).

Do not regenerate finished/published recordings, reset preferences/caches, add a
product CLI/Python runtime, introduce another worker mode, or operate live services
as part of routine fixture validation. Continue authorized implementation stages
after their automated gates pass; operator quality/service gates stay separate.
