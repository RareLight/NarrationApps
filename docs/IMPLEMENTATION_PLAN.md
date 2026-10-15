# Current implementation and remaining work

Updated October 15, 2026. Native unification and Kokoro LF0–LF7 implementation were
authorized and their automated integration gates are complete. This is the current
roadmap; the [original staged plan](history/UNIFICATION_PLAN.md) is historical.

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

## Next work

1. Complete the [consolidated operator checklist](OPERATOR_VALIDATION.md): GUI,
   actual private PDF/Markdown freeze reproduction, final samples/narration,
   OCR/caption quality, lifecycle and cross-app waiting. Live VoiceRelay Safari,
   Keychain, WebDAV, podcast playback and test-library restore remain operator-owned.
2. Implement/evaluate the [researched normalization increment](TEXT_NORMALIZATION_RESEARCH.md).
   Prioritize reproduced `kg`/temperature/time failures; keep the accepted pacing
   fixed. Preserve original blocks, composed replacement mappings and user-rule
   precedence, version acoustic/semantic identity, and evaluate contextual
   homographs without global substitutions or generative prose rewriting.
   It is not part of the currently accepted binary/sample baseline.
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
