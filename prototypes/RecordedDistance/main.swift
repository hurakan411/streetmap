import AppKit
import CoreLocation
import Foundation
// The app model's two UIKit color accessors are unused by these macOS checks.
typealias UIColor = NSColor

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let origin = CLLocationCoordinate2D(latitude: 35.7, longitude: 139.7)
let t = Date(timeIntervalSince1970: 1_792_200_000)
func point(_ meters: Double, _ seconds: Double, mode: TransportMode = .walking,
           speed: Double = 1.2, accuracy: Double = 8, estimated: Bool = false) -> GeoPoint {
    GeoPoint(latitude: origin.latitude + meters / 111_000, longitude: origin.longitude,
        timestamp: t.addingTimeInterval(seconds), horizontalAccuracy: accuracy, speed: speed,
        isEstimated: estimated, transportMode: mode)
}
let raw = stride(from: 0.0, through: 1_000, by: 10).map { point($0, $0) }
let inflated = stride(from: 0.0, through: 10_000, by: 100).map { point($0, $0 / 10) }
let track = WalkTrack(rawPoints: raw, matchedPoints: inflated, isRoadMatched: true)
let range = t.addingTimeInterval(-1)...t.addingTimeInterval(2_000)
let all = Set(TransportMode.allCases)
func summary(_ tracks: [WalkTrack], live: [GeoPoint] = [],
             range selected: ClosedRange<Date>? = nil, modes: Set<TransportMode>? = nil) -> RecordedDistanceCalculator.Summary {
    RecordedDistanceCalculator.summarize(tracks: tracks, livePoints: live,
        range: selected ?? range, modes: modes ?? all)
}
let actual = summary([track]).distance
require(actual > 990 && actual < 1_010, "An inflated directions route must never change the measured GPS distance")
require(abs(track.distance - actual) < 0.001, "Track-level distance must use the same measurement policy")
require(abs(summary([track], live: raw).distance - actual) < 0.001,
    "A just-finished track must not be counted twice with its live copy")
require(abs(summary([], live: raw).distance - actual) < 0.001, "In-progress GPS must update stats immediately")
require(summary([WalkTrack(rawPoints: raw, isEstimated: true)]).distance == 0,
    "A guessed recovery route is not measured distance")
require(summary([WalkTrack(rawPoints: [point(0, 0), point(100, 100, estimated: true)])]).distance == 0,
    "Estimated endpoints must not enter measured stats")
let clipped = summary([track], range: t.addingTimeInterval(250)...t.addingTimeInterval(750)).distance
require(abs(clipped - actual * 0.5) < 0.05, "The slider must clip crossing GPS legs proportionately")
require(summary([track], range: t.addingTimeInterval(2_001)...t.addingTimeInterval(3_000)).distance == 0,
    "An unrelated period must not include earlier movement")
require(summary([track], modes: []).distance == 0, "No transport selection must mean zero distance")
let cyclingRaw = raw.map { p -> GeoPoint in var p = p; p.transportMode = .cycling; p.speed = 5; return p }
let drivingRaw = raw.map { p -> GeoPoint in var p = p; p.transportMode = .automotive; p.speed = 15; return p }
let modes = [track, WalkTrack(rawPoints: cyclingRaw.map { p in
    var p = p; p.timestamp = p.timestamp.addingTimeInterval(2_000); return p
}), WalkTrack(rawPoints: drivingRaw.map { p in
    var p = p; p.timestamp = p.timestamp.addingTimeInterval(4_000); return p
})]
let wideRange = t...t.addingTimeInterval(6_000)
for mode in TransportMode.allCases {
    require(abs(summary(modes, range: wideRange, modes: [mode]).distance - actual) < 0.01,
        "Each transport filter must select only its own GPS movement")
}
require(abs(summary(modes, range: wideRange).distance - actual * 3) < 0.03,
    "All movement categories must sum without artificial loss")
let jitter = (0..<100).map { point(Double($0 % 2) * 4, Double($0), speed: 0, accuracy: 30) }
require(summary([WalkTrack(rawPoints: jitter)]).distance == 0, "Stationary GPS wiggle must not accumulate")
let spike = [point(0, 0), point(10, 10), point(1_000, 11), point(20, 20), point(30, 30)]
let spikeDistance = summary([WalkTrack(rawPoints: spike)]).distance
require(spikeDistance > 29 && spikeDistance < 31, "A GPS spike and its return must not create two long legs")
let slow = (0...12).map { point(Double($0), Double($0) * 2) }
require(summary([WalkTrack(rawPoints: slow)]).distance > 9, "Small real steps must accumulate rather than all being dropped")
require(summary([WalkTrack(rawPoints: [point(0, 0), point(200, 200)])]).distance == 0,
    "Do not invent distance across a GPS outage")
let badAccuracy = [point(0, 0), point(500, 10, accuracy: 140), point(20, 20)]
require(summary([WalkTrack(rawPoints: badAccuracy)]).distance == 0,
    "Poor fixes must break the chain, not bridge across an unknown segment")
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
let midnight = calendar.startOfDay(for: t)
var before = point(0, 0), after = point(100, 100)
before.timestamp = midnight.addingTimeInterval(-50)
after.timestamp = midnight.addingTimeInterval(50)
let crossing = RecordedDistanceCalculator.summarize(tracks: [WalkTrack(rawPoints: [before, after])],
    range: before.timestamp...after.timestamp, modes: all, calendar: calendar)
require(crossing.activeDays.count == 2, "A real movement spanning midnight must activate both days")
print("PASS: raw GPS not directions; live updates; deduplication; estimates excluded; time clipping; transport filters; jitter/spikes; slow walking; missing fixes; midnight")

// Optional local-only regression against an existing device backup. No raw
// coordinates, addresses, or individual routes are printed or transmitted.
if CommandLine.arguments.count > 1 {
    struct Archive: Decodable { let tracks: [WalkTrack] }
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(Archive.self, from: data)
    let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17))!
    let dayRange = day...day.addingTimeInterval(86_400)
    let start = ProcessInfo.processInfo.systemUptime
    let revised = RecordedDistanceCalculator.summarize(tracks: archive.tracks,
        range: dayRange, modes: [.walking], calendar: calendar)
    var previous = 0.0
    for track in archive.tracks {
        for (a, b) in zip(track.displayPoints, track.displayPoints.dropFirst()) {
            guard b.resolvedTransportMode == .walking, dayRange.contains(min(a.timestamp, b.timestamp)) else { continue }
            let d = a.location.distance(from: b.location)
            if d >= 2 { previous += d }
        }
    }
    require(revised.distance > 0 && revised.distance < previous,
        "The device's existing inflated history must recalculate without dropping all movement")
    print(String(format: "Existing history (Oct 17 walking): before %.3f km; revised %.3f km; active days %d; %.3fs",
        previous / 1_000, revised.distance / 1_000, revised.activeDays.count,
        ProcessInfo.processInfo.systemUptime - start))
    let preservedData = try Data(contentsOf: url)
    require(preservedData == data, "The original archive must remain byte-identical")
}
