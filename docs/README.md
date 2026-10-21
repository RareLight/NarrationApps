# Documentation index

Current guidance, October 19, 2026. Workspace/project paths are relative to the
NarrationApps root; package source, preparation-tool and historical package-build
paths are relative to `swift-packages/` unless stated otherwise. Start with the document for the task; historical
stage records are reference evidence, not additional operating instructions.

| Document | Purpose |
| --- | --- |
| [Architecture](ARCHITECTURE.md) | Current processing, ownership, worker/audio/recovery contracts |
| [Contributing](../CONTRIBUTING.md) | Repository ownership and safe native setup |
| [Development gates](DEVELOPMENT.md) | Quick/full/native/release commands and bounded evidence |
| [CI activation](CI.md) | Inactive self-hosted template, local entry points and external prerequisites |
| [Regression corpus](REGRESSION_CORPUS.md) | Canonical synthetic fixtures and mandatory contracts |
| [Current status](IMPLEMENTATION_STATUS.md) | Accepted baseline, latest automated evidence and open operator gates |
| [Development foundation checklist](DEVELOPMENT_FOUNDATION_CHECKLIST.md) | Staged setup, validation/CI, regression, organization, formatting and maintenance work |
| [Original foundation handoff](AGENT_HANDOFF_DEVELOPMENT_FOUNDATION.md) | Implementation-request provenance; current completion is in the checklist/status |
| [Remaining work](IMPLEMENTATION_PLAN.md) | Current roadmap, proposed features, acceptance and distribution/package-release work |
| [Cover art and navigation stages](COVER_ART_AND_NAVIGATION_PLAN.md) | Implemented export/feed covers, outlines, heading dedup and narration controls; evidence and acceptance gates |
| [Operator checklist](OPERATOR_VALIDATION.md) | Single current manual validation list, separated by app |
| [Repository layout and migration](REPOSITORY_LAYOUT.md) | Monorepo layout, private assets and original-folder archival gates |
| [Package boundaries](PACKAGE_BOUNDARIES.md) | Local Xcode/SwiftPM integration and independent releases |
| [Document processing](DOCUMENT_PROCESSING.md) | PDF/OCR, semantic source fidelity, images and deduplication |
| [Narration cleanup](DOCUMENT_CLEANUP.md) | Citation choices, recurring margins, supported columns and private text review |
| [Scientific narration](SCIENTIFIC_NARRATION.md) | Simple equations, one complex-math notice, prose insets, numeric tables and local text flow |
| [Academic PDF evaluation](ACADEMIC_PDF_EVALUATION.md) | Broader public-paper corpus, native/OCR/HTML comparisons and recommended extraction work |
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
