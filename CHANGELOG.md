# Changelog

Development milestones for the NarrationApps monorepo. Marketing versions are
authored in `Version.xcconfig`; the build number is the commit count stamped at
build time by `scripts/generate-app-info.sh`. These entries track development
history only - they are not release or distribution acceptance.

## Unreleased

- Libro adopts calendar version `2026.11.1`. Both apps track their own monthly
  release cycle in `Version.xcconfig` and stamp build numbers from Git history.
- VoiceRelay uses one Articles list with automatic preparation, narration status
  and a per-article reprocess action. Existing audio suppresses automatic duplicates.
- **Needs Attention** above Articles opens the rows with preparation or narration
  issues and their retry actions.
- VoiceRelay routes its library, Settings, article preview, Help and setup
  windows onto one Space: a window opens on the active Space when none exist,
  or joins the Space that already has a VoiceRelay window. Open windows are
  never moved between Spaces.

- Libro can force fresh Apple Vision OCR for individual queued PDFs, including
  searchable scans with an inaccurate embedded layer.
- All voices read just the hostname of supported web addresses while retaining
  the full links and source mappings.
- VoiceRelay can remove completed Server Audio episodes during generation. Queued
  and finalizing episodes stay protected. Accepted rows disappear together, and
  unfinished removals return for retry. The list uses stable row and
  footer heights so background cleanup does not shift the next delete target.
- Server Audio shows color-coded publishing and removal icons beside episode
  titles, with status details available on hover and to VoiceOver.
- Articles and Server Audio show compact ISO saved dates — `website.com
  (2026-11-13)` — and Server Audio joins audio duration and file size on the
  same line. Row status and action symbols share one size and spacing across
  Articles, Upload Queue and Server Audio at every text size.
- The VoiceRelay menu keeps one fixed-height status line and one command-height
  sync progress row, so background checks and phase changes never shift the
  popover contents. Progress details remain available by hovering the sync row.
- The menu shows **Updated** with today's time, an ISO date, or Unknown, and its
  green **Ready** now means no actionable issue while background checks keep
  running — orange setup and red failure statuses still open their Settings pane.
- Articles offer **Re-process Audio** on any idle current entry without matching
  audio, so a Reading List article whose server audio was deleted can be
  regenerated explicitly once its removal settles. Row action symbols sit closer
  together in Articles and Server Audio, and Articles vertically centers its row
  actions within native list rows.
- VoiceRelay's Upload Queue keeps rows compact — transient transfer,
  reconciliation and processing status now lives in a permanently reserved
  status bar below the list, so phase changes never shift row heights.
- Both apps put pronunciation entry format guidance in the shared info popover.
  Incomplete and malformed drafts stay unsaved. Duplicate, conflict, storage and
  preview errors remain visible.

- Libro 0.4.0 / VoiceRelay 0.3.0 development milestone: MP3/M4A/M4B exports and
  VoiceRelay podcasts gain source-derived embedded chapters
  with measured audio positions, show notes and safe bulleted source links.
  Optional on-device Apple Intelligence summaries are limited to 1-3 sentences
  and 50 words; oversized sources are skipped. Existing recordings are unchanged.

- VoiceServer accepts `response_format: "json"`, a complete-file
  `application/json` envelope (`{"audio": "<base64>", "content_type":
  "audio/mpeg"}`) for clients whose stacks cannot consume binary bodies;
  verified end to end from a scripted client. Existing mp3/wav/pcm
  responses and rejection behavior are unchanged.
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
- VoiceRelay article admission and audio generation now wait until enabled
  Publishing completes a reconciliation check against the current feed folder,
  so existing server audio is recovered instead of regenerated or re-uploaded.
  Changing the destination invalidates the recorded check.
- VoiceServer Settings gains a guided first-run setup sheet covering access,
  addresses, response mode, explicit key generation and enablement; passive
  status refreshes no longer flicker its controls. The menu-bar popover
  activates the app on show so the menu takes keyboard focus immediately.
- Project documentation was consolidated: dated implementation records moved to
  `docs/archive/`, the index routes by task, and the VoiceServer guide documents
  the exact client HTTP header contract.

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
