# Shinjuku simulator routes

Eight synthetic walks expand the existing northern demo network west, south and east.
Their geometry was obtained from MapKit walking directions on 2026-10-21 and is
bundled in `SampleHistory.makeRoutedStationRoutes` in `Michi/Store/AppStore.swift`.
The simulator uses `makeShinjuku`; physical devices keep their real history.

Destinations: Nishi-shinjuku-gochome, Nakano-sakaue, Hatsudai, Sangubashi,
Sendagaya, Shinjuku-gyoemmae, Yotsuya-sanchome and Wakamatsu-kawada stations.
These are public demo locations, not a person's location history.

The Shinjuku-gyoemmae route is a denser neighbourhood stroll, not a direct station
transfer: 22 MapKit walking legs through Shinjuku 3/4-chome, the Hanazono-jinja
area and streets north of the garden (about 6 km / 80 minutes at 1.25 m/s).
The other seven surrounding station routes are unchanged.

Regenerate the route coordinates on macOS (network access to Apple is required):

```sh
xcrun swiftc -parse-as-library prototypes/SimulatorRoutes/Generate.swift -o /private/tmp/streetprint_simulator_route_generator
/private/tmp/streetprint_simulator_route_generator
```

To regenerate the dense walking route instead of the eight direct routes:

```sh
/private/tmp/streetprint_simulator_route_generator --stroll
```

The generator prints encoded polylines; update the corresponding raw strings in
`AppStore.swift`. Do not substitute sparse straight-line waypoints or request
these routes on each simulator launch.

The regression harness in `main.swift` is compiled with the **actual** SampleHistory
enum extracted from `AppStore.swift`, plus the model, recording and distance services.
It checks 35 total routes (27 existing + 8 added), road geometry, common origin,
walking timestamps, no future points, fixture replacement and expanded map bounds.
