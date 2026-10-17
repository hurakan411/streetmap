# Plaster relief material study

Standalone macOS/Swift rendering test; not linked to the iOS app. No app UI or device installation changes are made by running this program.

```sh
xcrun swiftc -O -module-cache-path /private/tmp/StreetPrintMaterialModuleCache prototypes/PlasterRelief/main.swift -o /private/tmp/streetprint_relief_study
/private/tmp/streetprint_relief_study /Users/hashinokuchishougo/Documents/ChatGPT/map
```

The first run needs MapKit access to acquire a demo-area background, unless a previous study's map is already cached. No personal route history is read.

## v3

- Three reusable, deterministic 768×768 height stamps. Their silhouette profile is separate from their fracture widths.
- Broad irregular breaks; narrow, steep sidewalls instead of wide bevels.
- Local strata and occasional small remnants; no fractal edge noise.
- Slightly oblique viewing rays, height-derived normals, ambient occlusion, and cast shadows.
- Uses the existing plaster image only for subtle surface detail.

Outputs: `output/materials/relief-study-v3/`.

`relief-detail.png` is an exact 1:1 region of the rendered output; `relief-clay-preview.png` isolates lighting and geometry; `fracture-height-*.png` visualize the reusable height assets. The render itself samples floating-point height arrays, not quantized preview PNGs.

This is a material/shape study, not a finished route overlay. The test opening is a synthetic path. Tile seams, pan/zoom behavior, stable placement in map coordinates, GPU performance, and attribution placement still need separate integration/verification after visual approval.

## Reference material study v4

`ReferenceMaterialPreview.swift` is a separate native SwiftUI view that displays the reference-derived RGBA plaster material over the actual cached MapKit snapshot. It does not use the procedural v3 contour or claim to follow recorded routes.

```sh
xcrun swiftc -O -parse-as-library -module-cache-path /private/tmp/StreetPrintMaterialModuleCache prototypes/PlasterRelief/ReferenceMaterialPreview.swift -o /private/tmp/streetprint_reference_material_preview
/private/tmp/streetprint_reference_material_preview /Users/hashinokuchishougo/Documents/ChatGPT/map
```

Outputs: `output/materials/reference-relief-v4/`. `plaster-overlay.png` is the generated transparent material; `prompt.md` records the exact prompt and provenance. `reference-material-preview.png` is the native view's render over a real map, with display-only saturation/contrast adjustments. The executable validates the presence of both fully transparent holes and near-opaque plaster (alpha ≥250) before rendering. The material's original alpha is retained.

The geometry and lighting are baked into this material. Approval of this study establishes a visual target, not completion of arbitrary-route reconstruction, height-map recovery, tiling, or the excavation mode implementation. No image is installed in the iOS app by this test.
