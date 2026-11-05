# Changelog

Development milestones for the NarrationApps monorepo. Marketing versions are
authored in `Version.xcconfig`; the build number is the commit count stamped at
build time by `scripts/generate-app-info.sh`. These entries track development
history only - they are not release or distribution acceptance.

## Unreleased

- Shared development versioning: Version.xcconfig milestones, commit-count
  build numbers stamped at build time, and native About metadata in both apps.
- Coordinated preparation now includes document extraction/previews and optional
  narration-review retention/repair. OCR, image and title time budgets exclude
  admission waits. Pending article removal cancels and joins preparation; snapshot
  hashing/encoding happens before the database transaction, with final revalidation.
- Opt-in CPU admission now covers Libro input discovery and cover operations,
  plus VoiceRelay queue-title preparation and chunk-count planning. Title edits
  and planning results revalidate saved state after admission waits; cancellation
  preserves existing text, queue changes and artwork.
- MP3 preparation preserves explicit unity scale through LAME's preset
  initialization, removing inherited preset attenuation from future encodes.
  Existing recordings are unchanged. Both apps embed/sign the pinned native codec.

## Libro 0.3.0 / VoiceRelay 0.2.0 - November 4, 2026

- VoiceServer adds authenticated model/voice metadata and speech routes,
  streaming MP3/PCM and complete MP3/WAV/PCM responses, bounded FIFO admission,
  cancellation, output limits and deadlines. It uses the existing selected voice;
  API output never enters podcast or retained-review storage.
- VoiceServer Settings adds explicit private access, Keychain key generation,
  copy/rotation, CLI-first Tailscale discovery and joined Stop/sleep/Quit handling.
  The listener defaults off. Native listening, client/network reachability and
  signed Keychain/GUI acceptance remain operator-owned.
- Production factories share API > Libro > podcasts coordination, cold frontend
  preparation and same-helper speech promotion. Compatible live demand can take
  over promotion before lower-priority generation. Owned scratch locks prevent
  cleanup before helper/writer shutdown.
- Libro Interrupted Batches restores original file access separately from Resume,
  preserving captured settings, sources, destination consent and verified PCM.
  Explicit checkpoint discard preserves recordings; verified-complete recovery
  records are cleaned after joined work. Legacy VoiceRelay preview/display reads
  now use CPU admission outside scheduling/writer ownership.

## Libro 0.2.0 / VoiceRelay 0.1.1 - November 3, 2026

- Narration prepares text with lightweight frontends for all five models and
  loads speech weights when generation starts. Libro's General settings add a
  maximum CPU-worker control for Qwen, Chatterbox and Orpheus token counting;
  Kokoro's neural pronunciation stays serialized. Existing audio is unchanged.
- These are development milestones; GUI, actual-book timing, listening and
  signed Xcode validation remain operator-owned.

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
