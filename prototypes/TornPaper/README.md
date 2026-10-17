# Route-dependent torn paper

The app uses `Michi/Views/TornPaperRenderer.swift`. The texture supplies only fine paper grain; route coordinates determine the opening, fibres, curl shading, underside, contact occlusion, and cast shadow. No fixed silhouette or generated map picture is used.

The current material is warm gray (`#CDC9C2`). The existing dark-template palette is retained for contrast. `TornPaperFineEdge` supplies quiet short surface fibres and a very thin ragged break. It contains no folded tabs, rolled ends, or broad white back face. Baked shadow pixels are discarded; the renderer shades the map beneath the actual rip using `PaperEdgeRelief`.

`PaperEdgeRelief` models a shallow lift of 0.8–6.8 screen points, returning continuously to the flat sheet across 4–10.5 points. It cannot roll over or form a loop. Surface shading stays between 95% and 104% of the matte sheet color, while the darker contact and soft directional cast shadow appear on the exposed map side. Per-column rip positions align the shadow to the sampled fibres. Route geometry still determines the opening.

The oversized `PaperCurlPatch`/`PaperCurlRasterizer` experiment is no longer invoked by the renderer. Its implementation is preserved in `Archive/TornPaperRenderer-v8-mesh.swift`; retained helper definitions support the old comparison tests only.

The world-aligned distance field, grain and rip sampling remain continuous across tile boundaries. Edge effects shrink at city-wide zoom. UI layout is unchanged.

### Interactive rendering

`ExcavationMaskRenderer` draws native cached `CGImage` tiles, removing the old PNG encode/decode round trip. `PaperTilePipeline` coalesces requests, prioritizes visible 128px previews, then refines visible tiles at up to 2× resolution. A one-tile pan margin and adjacent zoom previews are prepared in advance. During zoom, cached parent/child images keep the opening geographically aligned until the new level is ready. Uncached regions are covered with the paper color, never a blank/unmasked map. Jobs outside the current viewport neighborhood are canceled, including work already constructing a distance field.

`PaperSegmentIndex` is an immutable bounding-volume tree: tile jobs visit nearby streets rather than scanning the whole history. Distance comparisons use squared values, and flat-paper pixels bypass all edge shading. Preview fields use a 4-unit grid; final fields retain the original 2-unit grid and accepted material. The reveal radius remains 217.5m.

On a Mac, the deterministic 20,000-segment/four-tile benchmark measured 296.6ms for the prior 3× renderer, 35.6ms for the new preview, and 145.4ms for the new 2× final render (PNG encoding is excluded from both). These are local renderer measurements, not claims about measured iPhone frame rates. `Performance.swift` can be compiled with the current renderer, or with `-D PAPER_BASELINE` and the pre-optimization source for comparison.

The app's static shared material is passed to the renderer. If an asset cannot be decoded, a procedural thin-fibre fallback still draws a route-dependent reveal. No fixed cutout or map image is installed in the app. Current asset provenance and prompt are in `output/materials/torn-paper-v9-thin-edge/asset-notes.md`.

## Renderer checks

```sh
xcrun swiftc -O Michi/Views/TornPaperRenderer.swift prototypes/TornPaper/main.swift -o /private/tmp/streetprint_torn_paper_tests
/private/tmp/streetprint_torn_paper_tests /Users/hashinokuchishougo/Documents/ChatGPT/map
```

Tests cover bounded shallow relief, a continuous return to the flat sheet, directional shadow falloff, warm-gray color, hit testing, empty/full paper coverage, added routes, deterministic rendering, cancellation, adjacent tile continuity, four zoom levels, theme-independent alpha, and premultiplied alpha. Old mesh/ribbon helpers retain isolated regression checks for the archived comparisons. For cloud-backed source folders, copy sources to a local build directory first so File Provider metadata changes do not invalidate compilation.

The tests also exercise index pruning with distant and long horizontal routes, preview/final staging, duplicate-request coalescing, rapid viewport changes and invalidation. Pass `--reference /absolute/path/to/a/prior-test-tile.png` to compare the final material against a prior 3× render after normalizing PNG premultiplication.

`Preview.swift` records the initial material study. `CurledPreview.swift` uses the current renderer and a correctly centered MapKit viewport. Both use simulator fixture routes, not personal location history. Current preview outputs are under `output/materials/torn-paper-v9-thin-edge/`. Passing `--detail` renders the central half of that geographic area at the next tile zoom for edge inspection. Earlier renders remain in their versioned folders.

`Archive/TornPaperRenderer-v1.swift` and `Archive/TornPaperRenderer-v6-textured.swift` preserve earlier sources. They are not compiled into the app.
