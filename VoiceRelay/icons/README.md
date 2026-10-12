# VoiceRelay — Glass Beacon icon

VoiceRelay turns saved articles into a private audio feed. The icon combines an
article card, a frosted circular voice disc and two outward broadcast arcs. It
shares Libro's original five-bar voice motif, soft glass edges, layered depth
and restrained palette, while its round silhouette and copper color distinguish
the apps even at small sizes.

## Files

- **`VoiceRelay.icon`** — authoritative, editable Icon Composer document. Eight
  transparent SVG layers in four native material groups; all assets embedded.
- **`Design/VoiceRelay-Beacon.af`** — editable Affinity vector master.
- **`Design/VoiceRelay-Beacon.svg`** — portable master with eight named groups.
- **`Design/Layers/`** — matching 1024 × 1024 SVG canvases for replacing individual
  Icon Composer images. Preserve these canvas dimensions and origins.
- **`Design/Concepts/`** — alternative Relay Cards and Speaking Bookmark studies.
- **`Previews/`** — native generation 27 renders for default, dark, tinted and
  clear appearances; 16/32/64/128 pixel size checks and a 1024 pixel default PNG.
- **`Exports/macOS/`** — compiled `Assets.car`, `VoiceRelay.icns`, generated icon
  plist keys and the successful, warning-free `actool` log.

The SVGs contain geometry and base colors only. Icon Composer supplies masking,
lighting, reflections, transparency, refraction and shadows. No generative
imagery or copied SF Symbol outlines are included.

## Material recipe

All groups use Individual mode with blur disabled. Review and export use design
generation 27.

| Front to back | Layers | Translucency | Specular | Neutral shadow | Refraction |
|---|---|---|---|---|---|
| Broadcast Arcs | outer, inner | 14% | Outside | 28% | Off |
| Raised Voice | voice | 8% | Outside | 50% | Off |
| Glass Disc | face, rim | 22% | Automatic | 50% | 24% strength, 8% height |
| Reading List | lines, front card, back card | 12% | Automatic | 40% | Off |

The native automatic gradient starts from sRGB `#7E3926`. Dark appearance uses
System Dark for the disc face and System Light for voice bars, article card and
broadcast arcs. This retains contrast while keeping the copper rim. System
tint/clear adaptation keeps the composition distinguishable from Libro by shape.

## Add to the VoiceRelay Xcode project

The supplied folder contained no app source/project, so this delivery validates
the icon independently and does not modify VoiceRelay's application code.

1. Add `VoiceRelay.icon` to the Xcode project and its app target's Resources.
2. Set **Asset Catalog App Icon Set Name** to `VoiceRelay`
   (`ASSETCATALOG_COMPILER_APPICON_NAME = VoiceRelay`).
3. Build with Xcode 27 for the app's supported macOS deployment target. The
   compiler generates the icon plist entries and both native/fallback resources.
4. Confirm the new icon in Finder and the Dock after running the rebuilt app.

Use the `.icon` source for Xcode integration. `Assets.car` is a standalone
validation output; do not replace an app's existing catalog with it, because
that could remove unrelated resources. The `.icns` is also available for an
existing build/distribution workflow that needs a static Mac icon.

For shape edits, use the Affinity master and replace the matching layer image
in Icon Composer. For material and appearance edits, use the `.icon` document.

## Validation — October 11, 2026

- Opened and inspected the eight editable vector groups in Affinity; saved the
  native `.af` master.
- Opened the four material groups in Icon Composer and adjusted disc refraction,
  depth, transparency and dark fill. Verified native rendering of the document.
- Exported and visually inspected all six supported `ictool` renditions:
  Default, Dark, TintedLight, TintedDark, ClearLight and ClearDark.
- Exported independent small-size renders. At 16 pixels fine page lines are
  secondary; the circular body and outward arcs carry recognition.
- Apple's macOS `actool` accepted the icon at deployment target 27.0, with no
  warnings or errors. Generated plist declares `CFBundleIconName = VoiceRelay`
  and `CFBundleIconFile = VoiceRelay`.
- App integration, an app build and Dock/Finder acceptance remain separate,
  because the VoiceRelay source project was not present in this folder.

Reproduce a preview:

```bash
'/Applications/Icon Composer.app/Contents/Executables/ictool' \
  /path/to/private-file --export-image \
  --output-file /path/to/private-file \
  --platform macOS --rendition Default --width 512 --height 512 --scale 1 \
  --design-generation 27
```

The design follows the same original-vector workflow as Libro. Apple's
[SF Symbols guidance](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
prohibits their use in app icons; the voice motif and other geometry here are
independently drawn. Material workflow references include the installed Icon
Composer controls and `ictool`, Apple's
[app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons),
and the supplied
[Icon Composer tutorial](https://antongubarenko.substack.com/p/wwdc26-icon-composer-for-beginners).
