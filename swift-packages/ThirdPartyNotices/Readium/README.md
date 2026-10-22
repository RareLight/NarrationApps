# Readium fragment-joining adaptation

Project source paths below are relative to `swift-packages/`; upstream paths refer
to the inspected Readium source tree. This is a project-authored adaptation record;
the original upstream copyright and license remain unchanged.

Source: Readium Swift toolkit draft [PR #877](https://github.com/readium/swift-toolkit/pull/877),
exact commit `3a50f066f0b050f2951c211b41cf69d8eab9be6a`.
Inspected October 17, 2026 via authenticated, read-only GitHub API; open/draft,
not merged at inspection.

`Sources/NarrationCore/PDFWordJoining.swift` adapts concepts and the line-ending
hyphen/lowercase continuation rule from
`Sources/Shared/Publication/Services/Content/Iterators/SentenceRegionBuilder.swift`,
with hard-break classification informed by `HardBreakDetector.swift`.
Those upstream files carry Copyright 2026 Readium Foundation. The repository's
original BSD-3-Clause license is retained in `LICENSE`.

This is a bounded native adaptation, not a Readium dependency or speech-engine
integration. It uses our UTF-16 projection maps and verified PDF geometry, adds
path/identifier exclusions, and defaults off behind an explicit captured narration
option. The initial adaptation inherited the draft's compound-word ambiguity.
The current project integration additionally checks the English lexicon: recognized
compound hyphens are preserved, recognized joined spellings may be repaired and
unknown alternatives abstain. Layout uncertainty remains experimental; original
extracted text is never replaced. Readium's broader iOS/
UIKit publication, search and TTS stack is not bundled.
