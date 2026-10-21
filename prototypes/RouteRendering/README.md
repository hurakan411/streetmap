# Persistent route rendering regression checks

Run from the repository root:

```sh
xcrun swiftc -O Michi/Models/WalkModels.swift Michi/Services/RecordedDistanceCalculator.swift Michi/Services/RecordingProcessor.swift Michi/Services/RouteGeometry.swift Michi/Views/RouteRenderPlan.swift prototypes/RouteRendering/main.swift -o /private/tmp/streetprint_route_plan_tests
/private/tmp/streetprint_route_plan_tests
```

An optional private history JSON argument exercises all transport-mode combinations without writing history. Never commit private history or geographic screenshots.

One geographic MKOverlay stays registered across pan/zoom and filter animations. A generous content envelope avoids replacing it for ordinary city recording updates. Camera delegates never register/remove route overlays. Immutable transition plans and their spatial index are prepared off the main thread. Animation only advances an index and invalidates changed bounds. Drawing queries visible entries in MapKit's tile rectangle.

Each segment keeps its exact coordinates, frequency opacity, round caps and independent translucent stroke. Width is explicitly specified in screen points (divided by MapKit zoomScale); the native renderer's zoom-dependent stroke properties are not used. No sampling, geometry simplification or joining endpoints is performed. The previous viewport-pruning/detail-overview swap is removed: physical-device measurements found that registering/removing thousands of overlays caused main-thread stalls of 2–3 seconds.

Tests cover exact reverse chronological removal and chronological addition, changed frequency/geometry replacement, interrupted transitions, no-op reuse, spatial culling, palette lifetime and final filtered membership. Actual production-renderer bitmap tests verify line width and position at five zoom scales and 1x/2x/3x display scales, plus empty output after removal. Test coordinates avoid wrapping the antimeridian. Optional private-history tests keep one surface across all mode combinations.

Host preparation/frame-bookkeeping timings and offscreen raster tests do not measure attached MapKit compositing or iPhone FPS. Validate attached-map alignment, widths, filter removal, map/routes-only/cover changes and wide zoom separately. Diagnostic builds identify this version with routeRenderer=persistentScreenPointV1; compare the same device, viewport, period and filters before claiming physical-device improvement.
