import AppKit
import Foundation
import CoreLocation
typealias UIColor = NSColor

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

// Independent copy of the pre-optimization stat semantics for equivalence.
func referenceStats(_ tracks: [WalkTrack], live: [GeoPoint], range: ClosedRange<Date>,
                    modes: Set<TransportMode>, calendar: Calendar) -> WalkStats {
    guard !modes.isEmpty else { return .zero }
    let measured = RecordedDistanceCalculator.summarize(tracks: tracks, livePoints: live,
        range: range, modes: modes, calendar: calendar)
    var firstSeen: [String: Date] = [:]
    var visible = Set<String>()
    for track in tracks.sorted(by: { $0.startDate < $1.startDate }) {
        for pair in zip(track.displayPoints, track.displayPoints.dropFirst()) {
            guard pair.1.connects(from: pair.0), modes.contains(pair.1.resolvedTransportMode) else { continue }
            let key = SegmentKey.make(pair.0, pair.1)
            let date = min(pair.0.timestamp, pair.1.timestamp)
            if firstSeen[key] == nil { firstSeen[key] = date }
            guard date >= range.lowerBound, date <= range.upperBound,
                  pair.0.location.distance(from: pair.1.location) >= 2 else { continue }
            visible.insert(key)
        }
    }
    let roads = visible.filter { firstSeen[$0].map(range.contains) ?? false }.count
    return WalkStats(newRoads: roads, distance: measured.distance, activeDays: measured.activeDays.count)
}

func sameSegment(_ a: WeightedSegment, _ b: WeightedSegment) -> Bool {
    a.id == b.id && a.start.latitude == b.start.latitude && a.start.longitude == b.start.longitude
        && a.end.latitude == b.end.latitude && a.end.longitude == b.end.longitude
        && a.frequency == b.frequency && a.isEstimated == b.isEstimated
        && a.firstVisitedAt == b.firstVisitedAt && a.transportMode == b.transportMode
}

let start = Date(timeIntervalSince1970: 1_792_200_000)
var tracks: [WalkTrack] = []
for day in 0..<12 {
    let points = (0..<80).map { i -> GeoPoint in
        var point = GeoPoint(latitude: 35.7 + Double(i) * 0.00005,
            longitude: 139.7 + Double(day % 3) * 0.00002,
            timestamp: start.addingTimeInterval(Double(day * 86_400 + i * 8)),
            horizontalAccuracy: 5, speed: 1.2)
        point.transportMode = TransportMode.allCases[day % TransportMode.allCases.count]
        if i == 30 { point.pathBreakBefore = true }
        return point
    }
    tracks.append(WalkTrack(rawPoints: points))
}
if CommandLine.arguments.count > 1 {
    struct Archive: Decodable { let tracks: [WalkTrack] }
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    tracks = try decoder.decode(Archive.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))).tracks
}
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
let lower = tracks.map(\.startDate).min() ?? start
let upper = max(lower.addingTimeInterval(1), tracks.map(\.endDate).max() ?? start)
let span = upper.timeIntervalSince(lower)
var cases = 0
var prepareTimes: [Double] = []
for fraction in [0.0, 0.25, 0.5, 0.9] {
    let range = lower.addingTimeInterval(span * fraction)...upper
    let relevant = tracks.filter { $0.endDate >= range.lowerBound && $0.startDate <= range.upperBound }
    let expectedSegments = RouteSegmentBuilder.build(tracks: relevant, range: range)
    for mask in 0..<8 {
        let modes = Set(TransportMode.allCases.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil })
        let live = Array(tracks.last?.rawPoints.suffix(15) ?? [])
        let began = ProcessInfo.processInfo.systemUptime
        let result = RouteDisplayPreparation.prepare(tracks: tracks, livePoints: live, range: range,
            modes: modes, calendar: calendar)!
        prepareTimes.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
        require(result.segments.count == expectedSegments.count, "No segment may be dropped")
        require(zip(result.segments, expectedSegments).allSatisfy(sameSegment), "Geometry, frequency and chronology must match")
        require(result.stats == referenceStats(tracks, live: live, range: range, modes: modes, calendar: calendar), "Stats must match all mode/range filters")
        let cached = RouteDisplayPreparation.prepare(tracks: tracks, livePoints: live, range: range,
            modes: modes, calendar: calendar, reusableSegments: result.segments)!
        require(cached.signature == result.signature && cached.stats == result.stats, "Cache reuse must not change output")
        cases += 1
    }
}
let all = RouteDisplayPreparation.prepare(tracks: tracks, livePoints: [], range: lower...upper,
    modes: Set(TransportMode.allCases), calendar: calendar)!
let signatureStart = ProcessInfo.processInfo.systemUptime
var signature = 0
for _ in 0..<10_000 {
    var hasher = Hasher(); hasher.combine(all.signature)
    for mode in TransportMode.allCases { hasher.combine(mode.rawValue) }
    signature ^= hasher.finalize()
}
let signatureMs = (ProcessInfo.processInfo.systemUptime - signatureStart) * 1000 / 10_000
print("PASS: \(cases) range/mode cases; identical geometry/order/frequency/stats; no archive writes")
print("Saved-route geometry: \(all.segments.count) reusable native lines; UI signature ms: \(signatureMs); worker preparation mean ms: \(prepareTimes.reduce(0,+) / Double(prepareTimes.count)); guard: \(signature)")
