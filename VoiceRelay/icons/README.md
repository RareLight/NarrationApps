# VoiceRelay icon sources

The Xcode app builds the canonical Icon Composer document at
[`../icon/VoiceRelay.icon`](../icon/VoiceRelay.icon). Edit that native document
for shipped icon changes.

`Design/VoiceRelay-Beacon.af` and `Design/VoiceRelay-Beacon.svg` are retained
editable vector masters; `Design/Layers/` holds the source layer geometry and
`Design/Concepts/` retains authored alternatives. These are design sources,
not runtime dependencies.

The duplicate Icon Composer package, compiled exports and generated preview PNGs
were omitted during consolidation. Generate new previews/exports with Icon
Composer when needed; the build produces its own app assets.
