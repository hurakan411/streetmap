# Midnight Pulse hex cover

In excavation mode, Midnight Pulse uses `MidnightHexMask.swift` instead of the
torn-paper pipeline. The other two templates retain their existing paper material.
UI layout, controls, route styles, and map attribution are unchanged.

Whole flat-top hex cells cover unexplored areas. Cell centers within the existing
326.25 m route reveal radius are uncovered. The lattice is anchored to map
coordinates with a 1024-map-point radius. A projected layer canvas makes the
pieces move, rotate and scale naturally with the map, without screen-fixed slots
or geographic grid rebasing. Hidden map POIs use the same geographic cell test.
Very broad overviews use a bounded raster cover instead of allocating thousands
of offscreen piece layers. This remains hex artwork, never a solid-color cover:
up to 12,000 candidate cells use the exact same geographic IDs, raised sprites
and cell-shaped reveal as the layer view. More extreme overviews use a cached
periodic hex texture anchored to the original world lattice and original radius,
with route openings. Cells are not enlarged, screen-fixed or geographically rebased.

The cached Core Graphics artwork has dark navy matte grain, upper-left beveled
highlights, lower-right cast shadows, and sparse embossed terrain marks. Pieces
have four stable geographic height tiers. A shared base plane is painted first,
then the pieces are drawn from low to high: slightly oversized, lifted top faces
overlap their lower neighbors, with shaded front walls and height-dependent cast
shadows.
No third-party assets, fixed map image, or paper texture is used.

Entering excavation mode drops full-sized pieces from above, in randomly scattered
batches of five (with a small individual timing offset),
with downward acceleration and a small landing rebound. Their size stays constant
throughout the fall. Only pieces intersecting the entry viewport are queued.
Core Animation moves cached sprite layers, without a display link, repeated map
overlay redraws, or route/projection queries on animation frames. Airborne pieces
draw above landed pieces; the sequence finishes within two seconds.

Pan, zoom, layout, and route/filter updates preserve in-flight placements and
never queue another fall. Newly appearing cells display immediately. Every child
of the actual Core Animation placement group has an explicit nonzero duration;
routine refreshes do not remove the group's animations. Reduce Motion displays
the final state. The cover view is hosted above map content and below native
MapKit controls/attribution; app controls retain their existing layout. Shared
snapshots finish any entry animation before capture.

Camera updates transform the geographic canvas immediately. Coverage and layer
membership are rebuilt only after crossing an 18% overscan margin or changing
route data. Cell reveal tests are cached per route revision; entry capture uses
three projections total rather than MapKit conversions per cell. Existing layers
keep their properties and animations. Above a 900-cell viewport estimate (700 to
return), a geographically anchored, at-most-1,200-pixel raster is reused through
pinches/pans instead of thousands of layers and per-frame route rasterization.
Rasterization runs on a single background worker, coalesces obsolete requests,
and rejects stale results. While it renders, the previous geographic image keeps
following the map. Route capsules are cleared individually to avoid expensive
union calculations for heavily overlapping histories.
The regression includes 20,000 route segments and 240 continuous camera updates.
Additional regressions exercise both raster detail levels and world-scale zoom,
verify non-flat tile artwork and cancellation, and export
`hex-overview-medium.png` / `hex-overview-far.png` for visual inspection.

Run the geographic/entry-only and actual animation-duration regression checks:

```sh
xcrun swiftc -O Michi/Views/TornPaperRenderer.swift Michi/Views/MidnightHexMask.swift prototypes/MidnightHex/main.swift -o /private/tmp/streetprint_hex_tests
/private/tmp/streetprint_hex_tests /Users/hashinokuchishougo/Documents/ChatGPT/map/output/midnight-hex
```

`hex-filling.png` and `hex-settled.png` use an illustrative grid, not a real map.
`app-preview.png` is the implemented app running in the simulator with Shinjuku
fixture routes, all transport categories visible, Midnight Pulse, and excavation mode.
