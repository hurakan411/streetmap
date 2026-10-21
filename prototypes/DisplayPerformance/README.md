# Display-only performance regression checks

Run from the repository root (macOS/Xcode):

```sh
xcrun swiftc -O Michi/Models/WalkModels.swift Michi/Services/RecordedDistanceCalculator.swift Michi/Services/RecordingProcessor.swift Michi/Services/RouteGeometry.swift prototypes/DisplayPerformance/main.swift -o /private/tmp/streetprint_display_tests
/private/tmp/streetprint_display_tests
```

An optional private archive path exercises real histories read-only. Do not commit histories or coordinates. Tests compare every edge, frequency, chronological order and stat against the prior calculation for 32 date/mode combinations. Timings are host measurements, not device frame-rate claims.

Saved-route geometry is reused across period/mode changes. At detail zoom, warm transitions toggle existing native renderer alpha instead of repeatedly rebuilding all lines. Only a padded viewport is attached to MapKit; offscreen models stay cached without retaining their native tile renderers. Broad zooms use bounded native multi-polyline groups (see ../RouteRendering), retaining all geographic edges and temporal events. Geometry changes with an existing ID replace only that specific line. Models, difference sorting, and viewport spatial indexes are prepared off the UI thread. Rapid requests coalesce for 16 ms and obsolete work cannot publish. Native stroke settings are retained; translucent overlap compositing can differ in far-zoom batches.

The reverse removal / chronological addition sequence and the 1.65-second route work budget are retained. Stats retain the existing two-second animation. UI-only updates reuse map configuration and route signatures. Paper/hex mask indexes are prepared off the main thread; obsolete mask preparations are canceled. Route-only sharing queries spatially visible geometry instead of projecting all history.

See ../RouteRendering for transition and geometry-reuse checks. A proposed single custom raster surface was rejected after attached MapKit screen comparisons showed different native stroke widths, despite exact offscreen comparisons. It is not the shipped implementation. Inspect actual map rendering, not only offscreen stroke output.
