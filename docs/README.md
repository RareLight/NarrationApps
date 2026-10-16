# Documentation index

Current guidance, October 16, 2026. Workspace/project paths are relative to the
NarrationApps root; package source, preparation-tool and historical package-build
paths are relative to `swift-packages/` unless stated otherwise. Start with the document for the task; historical
stage records are reference evidence, not additional operating instructions.

| Document | Purpose |
| --- | --- |
| [Architecture](ARCHITECTURE.md) | Current processing, ownership, worker/audio/recovery contracts |
| [Current status](IMPLEMENTATION_STATUS.md) | Accepted baseline, latest automated evidence and open operator gates |
| [Development foundation checklist](DEVELOPMENT_FOUNDATION_CHECKLIST.md) | Staged setup, validation/CI, regression, organization, formatting and maintenance work |
| [Next-agent handoff](AGENT_HANDOFF_DEVELOPMENT_FOUNDATION.md) | Ready-to-paste implementation request for the foundation stages |
| [Remaining work](IMPLEMENTATION_PLAN.md) | Current roadmap, proposed features, acceptance and distribution/package-release work |
| [Cover art and navigation stages](COVER_ART_AND_NAVIGATION_PLAN.md) | Implemented export/feed covers, outlines, heading dedup and narration controls; evidence and acceptance gates |
| [Operator checklist](OPERATOR_VALIDATION.md) | Single current manual validation list, separated by app |
| [Repository layout and migration](REPOSITORY_LAYOUT.md) | Active parent, independent repositories, cleanup and archival gates |
| [Package boundaries](PACKAGE_BOUNDARIES.md) | Local Xcode/SwiftPM integration and independent releases |
| [Document processing](DOCUMENT_PROCESSING.md) | PDF/OCR, semantic source fidelity, images and deduplication |
| [Pronunciation](PRONUNCIATION.md) | Dictionary, matching, persistence, Settings and live previews |
| [Voice samples](VOICE_SAMPLES.md) | Current resources and one-argument regeneration utility |
| [Settings ownership](SETTINGS_ALIGNMENT.md) | Shared controls versus app-specific preferences/workflows |
| [Dependency record](DEPENDENCIES.md) | Exact native pins, patches, model/resource and codec provenance |
| [Source provenance](PROVENANCE.md) | Source origin, licenses/notices and preservation |
| [Longform evidence](KOKORO_LONGFORM_IMPLEMENTATION.md) | Reproducible comparisons, listening decision and final LF7 artifacts |
| [Normalization research](TEXT_NORMALIZATION_RESEARCH.md) | Reproduced lexical defects and the next proposed correction stage |
| [Text processing improvement plan](TEXT_PROCESSING_IMPROVEMENT_PLAN.md) | Accepted Delivery A listening; implemented TP4–TP7, evidence and B06 operator gates |

The former staged plans, app handoffs and naming investigation are retained in
Git history and the original repositories, rather than duplicated in the current
working tree. Use the current status, architecture and roadmap above.
