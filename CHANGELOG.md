# Changelog

Development milestones for the NarrationApps monorepo. Marketing versions are
authored in `Version.xcconfig`; the build number is the commit count stamped at
build time by `scripts/generate-app-info.sh`. These entries track development
history only - they are not release or distribution acceptance.

## Unreleased

- Shared development versioning: Version.xcconfig milestones, commit-count
  build numbers stamped at build time, and native About metadata in both apps.

## 0.1.0 - October 31, 2026

First tracked development baseline.

### Common

- Semantic phrasing is the only production preparation path for all five
  product models; speech setup validates automatically in the background with a
  shared `SpeechSetupValidation` controller - the Voice Model heading shows
  Validating, a green Ready, or Repair local model.
- Shared narration settings, typography and pronunciation tooling in the
  SwiftNarration/AppPresentation packages.

### Libro

- Automatic speech setup validation with explicit model download/repair,
  onboarding install or repair, and a discoverable Repair action beside the
  narration controls.

### VoiceRelay

- Podcast episodes carry a clickable publication-name source link in the item
  notes, including public PDF articles, with existing episodes picking it up on
  the next normal feed update.
