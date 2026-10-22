# Libro — Glass Folio icon

The app icon is a tilted, bound book with five original raised voice bars. Its
pale blue cover, visible spine and page block sit on a restrained indigo field.
The closed-book direction keeps a simple silhouette at Finder and Dock sizes;
the alternative open-book and spoken-document studies are in `Concepts/`.

## Editable sources

- `Libro-Folio.af`: vector master imported and saved in Affinity. Five named,
  editable groups; no generated imagery or rasterized edges.
- `Libro-Folio.svg`: portable vector master with the same geometry.
- `Layers/`: five transparent SVG canvases, each 1024 × 1024, with matching
  origins. Keep the canvas dimensions when replacing an image.
- `../../Libro/Resources/AppIcon.icon`: finished Icon Composer 2.0 document,
  containing all five SVG assets and the native material settings. This is
  the source Xcode compiles, not a flattened preview.

Edit shape geometry in Affinity and replace the corresponding image through
Icon Composer's Image control. Material and appearance edits belong in Icon
Composer. Its native mask, lighting, highlights and shadows are not baked into
the SVGs. Xcode's app target references `AppIcon.icon` in Resources and uses
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` in `App.xcconfig`.

## Material composition

All three groups use Individual mode, with blur disabled. Design generation 27
was used for the visual review and renders.

| Front to back | Layers | Translucency | Specular | Neutral shadow | Refraction |
|---|---|---|---|---|---|
| Raised Voice | voice | 8% | Outside | 50% | Off |
| Frosted Cover | spine, cover | 18% | Automatic | 50% | 28% strength, 6% height |
| Binding & Pages | pages, binding | 12% | Automatic | 40% | Off |

Background: native automatic gradient from sRGB `#23365C`. Dark appearance
explicitly uses System Light for the voice and page block; automatic dark fills
otherwise made the voice motif too faint. Tinted and clear appearances use the
system's adaptation.

## Review evidence — October 11, 2026

- Opened and inspected the original vector artwork in Affinity, then saved its
  native editable master.
- Assembled five images into three named groups and tuned native effects in
  Icon Composer. Inspected default, dark and monochrome UI previews, including
  the 32-point preview.
- Exported default, dark, tinted-light/dark and clear-light/dark PNGs with Apple's
  installed `ictool`, design generation 27. Reviewed rendered appearance output.
- Exported independent 16, 32, 64 and 128 pixel default renders. At 16 pixels the
  book silhouette carries recognition; fine page/material details are secondary.
- Debug Xcode 27 build succeeded with the resource integrated. The app has
  `CFBundleIconName = AppIcon`, compiled `Assets.car` and `AppIcon.icns`.
  `codesign --verify --deep --strict` passed. The icon compiler emitted no
  warnings; Xcode emitted its unrelated "Metadata extraction skipped, no
  AppIntents.framework dependency found" warning. No speech/runtime changes.
- Project plist syntax and `git diff --check` passed.

Generated review PNGs are omitted from the active checkout. Reproduce a preview
from `NarrationApps/Libro/` (create the output directory first):

```bash
mkdir -p macos/Design/LibroIcon/Previews
'/Applications/Icon Composer.app/Contents/Executables/ictool' \
  macos/Libro/Resources/AppIcon.icon --export-image \
  --output-file macos/Design/LibroIcon/Previews/default.png \
  --platform macOS --rendition Default --width 512 --height 512 --scale 1 \
  --design-generation 27
```

## Artwork and references

All book and voice geometry is original. The supplied SF Symbols collection was
consulted as a visual reference; its outlines are not included. Apple's
[SF Symbols guidance](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
prohibits using the symbols or confusingly similar images in app icons and logos.
This project therefore uses independently drawn shapes.

Material workflow references: Apple's
[app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons),
the installed Icon Composer 2.0 controls and `ictool --help`, and the supplied
[Icon Composer tutorial](https://antongubarenko.substack.com/p/wwdc26-icon-composer-for-beginners).

Any generated PNGs are review exports. The `.icon` package remains the authoritative app
icon; Affinity/SVG masters remain the authoritative shape sources. Aesthetic
approval is separate from successful compilation and visual inspection.
