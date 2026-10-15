# VoiceRelay documentation

| Guide | Purpose |
| --- | --- |
| [App guide](../README.md) | Build/setup and everyday source, queue, Publishing and backup use |
| [Architecture](ARCHITECTURE.md) | App-specific ownership, lifecycle, persistence and safety contracts |
| [Source handling](SOURCE_REVIEW.md) | Safari/web/PDF authorization, previews, archive lookup and provenance |
| [Native speech adapter](KOKORO_PROVIDER.md) | App/backend integration with shared prepared speech |
| [Server recovery](SERVER_RECOVERY.md) | Identity, reconciliation, proofs, conflicts and cleanup behavior |
| [Contributing](../CONTRIBUTING.md) | Safe engineering checks and source conventions |
| [Current validation](VALIDATION.md) | Automated evidence, operator ownership and source-only checks |
| [Consolidated operator checklist](../../swift-packages/docs/OPERATOR_VALIDATION.md#voicerelay) | Only current manual test list |
| [Release checklist](RELEASE_CHECKLIST.md) | Engineering/package and conditional distribution gates |
| [Shared docs](../../swift-packages/docs/README.md) | Canonical packages, parsing, pronunciation, samples, audio and remaining work |
| [Historical validation](history/VALIDATION.md) | Dated results from earlier implementations; commands/defaults may be retired |

Older [final-polish](history/FINAL_POLISH.md) and
[text/image intake handoff](history/TEXT_AND_IMAGE_INTAKE_HANDOFF.md) records are
historical references. Their active functionality is described in current guides;
their old commands are not an additional setup path.
