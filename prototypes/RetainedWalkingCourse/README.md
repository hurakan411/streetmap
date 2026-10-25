# Retained proposal (one course, no expiry)

Search results offer **Keep on map** (or **Replace saved**). On successful save, planning closes and the normal map keeps the orange proposal. Closing planning without saving leaves an existing retained proposal unchanged. The small **Course on map** control focuses its bounds; its separate × button removes the retained proposal and its saved file. Closing/relaunching the app does not remove it. There is no timer, daily expiry, geofence completion or automatic removal.

Persistence is a versioned, atomically written JSON file at `Application Support/Michi/retained-walking-course.json`, protected until first device unlock on iOS. Only the selected course is stored (geometry, metrics, stops and identity), never all search candidates. Invalid/nonfinite coordinates, malformed data, unsupported versions and oversized files are rejected. Save/clear failures do not change the in-memory retained route and are reported in an alert. An unreadable saved proposal does not block recording-history loading; a new valid selection can overwrite it.

The payload is not a `WalkTrack` and is never passed into recording history, novelty indexing, widgets or stats. Period/transport visibility filters do not filter the proposal. The empty-history message is hidden while a proposal is on the map, so it does not cover the course. Reusing the same selected course when closing planning preserves the existing proposal overlay; focusing or selecting another course changes only its camera/overlay, not the persistent history renderer. Background/mask insertions keep the proposal above them. Planning controls and the direction sector disappear outside planning.

```sh
xcrun swiftc Michi/Services/RetainedWalkingCourse.swift prototypes/RetainedWalkingCourse/main.swift -o /private/tmp/streetprint_retained_course_tests
/private/tmp/streetprint_retained_course_tests
```

Tests use a unique temporary directory, include an untouched history sentinel, and cover restore, replace, clear, corruption, validation and write failure. Simulator checks cover a real generated course retained on the normal map, restoration across process restart, focus and independent period filters. A retained course is a reference overlay, not turn-by-turn navigation or a live access/safety guarantee.
