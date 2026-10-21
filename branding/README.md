# Blitz Neo icon

Blitz Neo uses the cyan/blue/purple N and lightning emblem created for this
maintenance fork. It does not reuse the upstream Blitz logo. No trademark
clearance is implied. Original upstream notices remain intact.

## Application icon

`AppIcon.png` is the opaque, full-bleed native icon artwork. The build script
generates a macOS asset catalog with all standard sizes, then compiles it into
`Assets.car` and `AppIcon.icns` with the generated icon metadata. macOS applies
its current icon presentation to this single surface. An installed `.app` never replaces that icon with
a raw `NSImage` at runtime.

Created with the built-in Imagegen tool on 2026-10-21, using the standalone
icon below as its reference. The generated artwork is 1254 × 1254 pixels.

Production prompt:

> Use case: precise-object-edit. Asset type: production full-bleed square macOS application icon artwork, not a presentation render. Edit target: attached approved Blitz Neo icon. Preserve the exact cyan-blue-purple angular N/lightning emblem, its geometry and restrained shading. Fix ONLY the background/layout: extend the existing deep navy blue gradient background all the way to ALL FOUR EDGES and ALL FOUR CORNERS of the square canvas. There must be NO rounded tile boundary, NO transparent border or margin, NO external background, NO shadow around a tile, NO light/white/grey frame, NO nested squircle. The whole image is a single fully opaque square navy-gradient icon surface. Keep the N centered with balanced breathing room, roughly 76% of canvas width; do not crop the emblem. The operating system will apply rounded corners later. 1024 by 1024 pixels, straight-on flat icon artwork. No text, no wordmark, no other marks. Keep identity of original icon.

## Standalone artwork

`../src/resources/blitz-icon.png` retains transparency and rounded corners for
the welcome screen and non-bundle `swift run` fallback. The website uses this
standalone artwork too. It must not be used as the native app-icon artwork:
doing so produces a small rounded icon inside macOS's outer tile.

Created with Imagegen on 2026-10-21 from the original Blitz Neo concept sheet.
The returned source is 1254 × 1254 pixels, with genuine alpha transparency.
Internal resource names remain stable for compatibility.

Extraction prompt:

> Use case: background-extraction. Asset type: production macOS app icon for Blitz Neo. Input image: edit target, previously approved concept sheet. Extract and faithfully reproduce ONLY the large upper colored rounded-square app icon, preserving its exact navy rounded-square tile, cyan-blue-purple angular N/lightning emblem, gradients, shading and proportions. Remove the wordmark, lower monochrome icon and presentation background completely. Output one centered square 1024-by-1024 PNG icon asset. The tile should occupy about 88% of the canvas width and height, with balanced transparent margins and genuine alpha transparency around the tile; a subtle natural shadow is fine. No text, no extra marks, no second icon, no white rectangular background. Preserve the approved design rather than redesigning it.
