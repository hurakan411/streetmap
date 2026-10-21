# Recording pipeline regression

The new pipeline applies only to new recordings and newly recovered v3 drafts.
There is no launch-time migration, user-specific override, retrospective mode
rewrite or automatic re-routing of legacy history. Raw coordinates, timestamps,
reported speeds/accuracy and Core Motion snapshots remain available locally.

The independent stages are:

1. Validate positions, reject rapid GPS excursions and hold ambiguous jumps for
   subsequent observations. Keep every raw fix with a quality/reason annotation.
2. Use reliable speed, positional displacement and non-conflicting Core Motion
   evidence over time. Confirmation backdates an active transition, never a saved
   historical track. GPS inference does not manufacture motion-sensor events.
3. Apply the selected speed-capture policy only to confirmed windows. In all
   movement mode, pending transport never discards boarding observations.
4. Derive display geometry separately from distance-stat jitter suppression.
   A short plausible noise gap can reconnect; a real GPS outage cannot prove a
   road and remains disconnected. Recovery anchors no longer synthesize trips.
5. Accept MapKit directions only within a bidirectional GPS corridor, with sane
   observed/route length. Use local-leg transport, not one mode for a whole trip.
   Failed legs and request-budget exhaustion keep observed geometry, never only
   the longest successful fragment. Endpoints join exactly. Cancel stale work.
6. Group visit frequency approximately, but deduplicate displayed geometry only
   at the same endpoints. Adjacent short lines must not be erased by road buckets.

Thresholds are deliberate initial policy, not a claim of perfect detection.
Without enough reliable GPS or motion evidence, a transport mode is provisional;
missing locations cannot be reconstructed as known visited roads. Future field
testing can inspect per-point local reasons without changing sensor measurements.

```sh
xcrun swiftc -O Michi/Models/WalkModels.swift Michi/Services/RecordedDistanceCalculator.swift Michi/Services/RecordingProcessor.swift Michi/Services/RouteGeometry.swift prototypes/RecordingPipeline/main.swift -o /private/tmp/streetprint_pipeline_tests
/private/tmp/streetprint_pipeline_tests
```

Optionally pass a private device `walk-history.json` backup to replay the Oct 18
reported walk using its saved GPS (the old Core Motion stream was not saved).
Tests check sensor immutability, legacy serialization and that the input file is
unchanged. Only aggregate metrics are printed. Do not commit device backups,
coordinates, derived private images or local audit files to Git.
