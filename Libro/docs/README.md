# Libro documentation

| Guide | Purpose |
| --- | --- |
| [App guide](../README.md) | Build, setup, document/export workflow and current defaults |
| [Native build guide](../macos/README.md) | Xcode versus script workspace and model/setup/progress notes |
| [Troubleshooting](TROUBLESHOOTING.md) | Package errors, models, memory, diagnostics and output safety |
| [Voice selection](native-kokoro-voices.md) | Shared metadata, accepted default and sample behavior |
| [Validation](VALIDATION.md) | Current evidence and operator ownership |
| [Consolidated checklist](../../swift-packages/docs/OPERATOR_VALIDATION.md#libro) | Only current manual test list |
| [Shared architecture](../../swift-packages/docs/ARCHITECTURE.md) | Canonical intake/preparation/speech/audio/library contracts |
| [macOS design reference](macos-style-reference.md) | Reusable design conventions and historical Libro studies |

## Historical evidence

These records retain what was checked at their stated dates. They are not current
setup instructions, default settings or parallel/fallback modes:

- [October 8 Metal/debugging investigation](history/native-gui-debugging.md).
- [October 9 compact GUI refinement](history/native-gui-ux-checklist.md).
- [October 9 original voice ranking](history/native-kokoro-voices-2026-10-09.md).
- [October 11 native build-warning audit](history/native-build-warnings-2026-10-11.md).
- [October 12 memory incident and controlled reproductions](history/native-memory-2026-10-12.md).

Current shared [status](../../swift-packages/docs/IMPLEMENTATION_STATUS.md),
[roadmap](../../swift-packages/docs/IMPLEMENTATION_PLAN.md) and
[dependency record](../../swift-packages/docs/DEPENDENCIES.md) supersede the earlier
Libro-only unification plan. Existing model caches, private data and completed
recordings were not changed by the documentation consolidation.
