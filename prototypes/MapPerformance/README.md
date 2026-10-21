# Map interaction diagnostic build

Build optimized Release with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=STREETPRINT_DIAGNOSTICS`.
Do not distribute this flag in the App Store build. Normal builds have neither
the diagnostic UI nor active collection/alternative layer selections.

Settings → 描画の計測 offers normal presentation and three read-only layer stages:
map only, map + routes, and map + routes + the selected theme's paper/hex cover.
These override only MapCanvas input, never store filters, recording or history.
Use the same period, template, viewport, zoom range and transport filters.
Select a stage, start, and move the map after the three-second warm-up; the
default session lasts 20 seconds. Repeat each stage twice (warm and cold cache
effects differ). Do not change templates/filters during a measurement.
Return to normal presentation afterwards.

CADisplayLink intervals are recorded during camera movement and a 0.5-second
settling tail. They measure main-run-loop callback delivery, **not GPU presentation
FPS or GPU utilization**. Adaptive refresh budgets are respected; the probe does
not force a frame rate. An empty capture is explicitly marked insufficient data.
CPU/GPU attribution still requires a device profiler when these probes cannot
explain visible stutter. Operation scopes are wall-clock durations, can overlap
and nest, and must not be summed as CPU time.

Scopes cover view updates, camera callbacks, persistent route-surface registration,
animation-index updates and rendering, sharing projection, paper scheduling/raster
work, and hex projection/layer updates/raster work. Reports tagged with
`routeRenderer=persistentScreenPointV1` use one persistent route renderer rather
than camera-dependent native per-edge/overview overlays. Live route drawing is
sampled once per 16 calls; persistent surface draws are measured on every call.
Sampled counts/totals must not be interpreted as counts/totals for every draw.
Late workers cannot contaminate a later session. Backgrounding marks the session
interrupted. At most 12 reports remain in memory. No per-frame SwiftUI publishing
or per-frame disk writes occur.

The settings UI can share plain text through the system share sheet; it does not
send it automatically. A local copy is saved to `Library/Caches/MapPerformance/report.txt`.
Reports contain stage/template/filter presets, aggregate segment count and timing
data, but no GPS coordinates, route IDs or history. They do not survive in the
settings UI after a process restart (the cache copy remains).

Core regression test (ordinary, non-diagnostic build):

```sh
xcrun swiftc -O Michi/Views/MapPerformanceDiagnostics.swift prototypes/MapPerformance/main.swift -o /private/tmp/streetprint_map_performance_tests
/private/tmp/streetprint_map_performance_tests
```

Simulator measurements validate the instrumentation, not physical-device performance.
