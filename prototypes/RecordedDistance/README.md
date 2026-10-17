# Recorded distance regression

Distance is recomputed from `WalkTrack.rawPoints` and the current raw live route,
never from `matchedPoints` or directions results. Existing JSON archives need no
migration: raw points, matched display geometry, IDs and timestamps are retained.
The new interpretation applies equally to existing and future records.

Policy:

- Exclude explicitly estimated tracks/points from measured distance.
- Reject invalid coordinates, timestamps, negative/invalid accuracy, and fixes
  worse than the recorder's walking precision limit (65 m; 150 m for other modes).
- Do not connect across gaps over 180 seconds or rejected low-quality samples.
- Accumulate small real movements; suppress stationary displacement within the
  measurement uncertainty. Reject implausible spikes while keeping the last good
  anchor, so the return from a spike is not counted a second time.
- Apply the arrival point's existing transport classification, consistent with
  route filters. Sanity speed limits only reject extreme jumps; they do not
  replace transport detection or user capture settings.
- Clip each GPS leg proportionately at the selected period/slider boundaries.
- Deduplicate identical raw legs across saved/live state during track completion.
- Derive active days from the same accepted raw legs. New-road counts continue
  to use road geometry; this change does not invent or remove visited roads.

Raw GPS itself is not ground truth. Missing or excluded measurements are unknown,
not replaced with guessed road distance or a user-entered target distance.

Run the same production calculator and model against synthetic regressions:

```sh
xcrun swiftc -O Michi/Models/WalkModels.swift Michi/Services/RecordedDistanceCalculator.swift prototypes/RecordedDistance/main.swift -o /private/tmp/streetprint_distance_tests
/private/tmp/streetprint_distance_tests
```

An optional argument is a **local** `walk-history.json` backup. It prints only an
aggregate old/new comparison for the 2026-10-17 walking-distance regression and
verifies that the input archive is unchanged. Device histories, GPS coordinates
and private backups must not be committed to this repository.
