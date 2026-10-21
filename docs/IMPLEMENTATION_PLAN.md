# Current implementation and remaining work

Updated October 19, 2026. Native unification and Kokoro LF0–LF7 implementation were
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
Its [original handoff](AGENT_HANDOFF_DEVELOPMENT_FOUNDATION.md) records the authorized
scope; use current checklist/status evidence rather than restarting completed stages.
Local engineering and final gates are complete; official CI provider/action review,
source publication/activation and operator acceptance remain separate. Deferred
product features were not added to this scope.

## Next work

The authorized Readium-style PDF word-joining experiment is implemented in shared
NarrationCore/NarrationUI, off by default. Current evidence is in
[implementation status](IMPLEMENTATION_STATUS.md); actual-document/compound/listening
acceptance is operator B07, alongside the existing B06 baseline flow checks.
Libro's progressive preview/layout follow-up is implemented; first-page latency,
live layout and cancellation/reopening acceptance are operator L20.
The October 18 citation/margin/column follow-up is authorized, including read-only
text comparisons against the three operator-supplied books. Its scope and evidence
are in [narration cleanup](DOCUMENT_CLEANUP.md) and the current status.
The scientific-PDF follow-up adds conservative equation and table handling with
explicit source-reference fallbacks. Its scope and remaining transcription limits
are in [scientific narration](SCIENTIFIC_NARRATION.md); GUI/listening acceptance
is operator B08.
The [expanded academic evaluation](ACADEMIC_PDF_EVALUATION.md) records additional
public-paper tests and proposed structure-preserving intake, regional review and
math speech integration. Current priorities are readable inset prose in its local
text flow and one reference notice for complex equations. Advanced mathematical
transcription and those larger extraction changes remain deferred research.

1. Complete the [consolidated operator checklist](OPERATOR_VALIDATION.md): GUI,
   actual private PDF/Markdown freeze reproduction, final samples/narration,
   OCR/caption quality, lifecycle and cross-app waiting. Live VoiceRelay Safari,
   Keychain, WebDAV, podcast playback and test-library restore remain operator-owned.
2. Validate Delivery B of the [text-processing checklist](TEXT_PROCESSING_IMPROVEMENT_PLAN.md)
   through B06: paragraph/source fidelity, conservative PDF margin/continuation
   decisions, progress/cancellation and matched listening. Delivery A listening,
   including letter A, is operator accepted. TP4–TP7 engineering is implemented;
   unsupported complex layouts, chaptered audio, caption scheduling and broader citation/homograph
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
