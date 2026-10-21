import AppKit
import CoreLocation
import Foundation
typealias UIColor = NSColor

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
let start = Date(timeIntervalSince1970: 1_792_200_000)
func motion(_ mode: TransportMode, at second: Double, stationary: Bool = false) -> MotionEvidence {
    let date = start.addingTimeInterval(second)
    return MotionEvidence(startDate: date, receivedAt: date, confidence: 2,
        walking: mode == .walking, running: false, cycling: mode == .cycling,
        automotive: mode == .automotive, stationary: stationary)
}
func point(_ meters: Double, _ second: Double, speed: Double = 1.3,
           accuracy: Double = 8, evidence: MotionEvidence? = nil, east: Double = 0) -> GeoPoint {
    var p = GeoPoint(latitude: 35.7 + meters / 111_000, longitude: 139.7 + east / 90_000,
                     timestamp: start.addingTimeInterval(second), horizontalAccuracy: accuracy, speed: speed)
    p.speedAccuracy = 0.3
    p.reportedSpeedIsValid = true
    p.motionEvidence = evidence
    return p
}
func processed(_ points: [GeoPoint]) -> [GeoPoint] { RecordingProcessor.process(points) }
func sameSensors(_ a: GeoPoint, _ b: GeoPoint) -> Bool {
    a.latitude == b.latitude && a.longitude == b.longitude && a.timestamp == b.timestamp
        && a.speed == b.speed && a.horizontalAccuracy == b.horizontalAccuracy
        && a.speedAccuracy == b.speedAccuracy && a.motionEvidence == b.motionEvidence
}
let walking = (0...180).map { second in
    point(Double(second) * 1.3, Double(second), speed: (30...33).contains(second) ? 11.5 : 1.3,
          evidence: motion(.walking, at: 0))
}
let foot = processed(walking)
require(foot.allSatisfy { $0.resolvedTransportMode == .walking }, "A short speed burst must not create car/bicycle sections")
require(zip(walking, foot).allSatisfy(sameSensors), "All original sensor fields must survive processing")
require(foot.allSatisfy { $0.recordingEvidence != nil }, "Keep a local explanation for every decision")
var spike = walking
spike[70].latitude += 500 / 111_000
let clean = processed(spike)
require(clean[70].recordingEvidence?.coordinateStatus == "rejected", "Reject a GPS spike and return")
require(clean.count == spike.count && zip(clean, spike).allSatisfy(sameSensors), "Rejected fixes remain in the raw archive")
let geometry = RouteGeometry.observedPoints(from: clean)
require(!geometry.contains { $0.id == spike[70].id }, "A rejected coordinate is not a visited place")
require(!geometry.contains { $0.pathBreakBefore == true }, "A single noise point must not fragment an otherwise continuous walk")

let bus = (0...300).map { second -> GeoPoint in
    if second <= 60 { return point(Double(second) * 1.3, Double(second), evidence: motion(.walking, at: 0)) }
    if second <= 160 { return point(78 + Double(second - 60) * 10, Double(second), speed: 10, evidence: motion(.automotive, at: 61)) }
    if second <= 210 { return point(1_078, Double(second), speed: 0, evidence: motion(.automotive, at: 161, stationary: true)) }
    return point(1_078 + Double(second - 210) * 1.3, Double(second), evidence: motion(.walking, at: 211))
}
let ride = processed(bus)
require(ride.count == bus.count, "Do not drop boarding or alighting observations")
require(ride[61...160].allSatisfy { $0.resolvedTransportMode == .automotive }, "Backdate a confirmed bus transition to its beginning")
require(ride[180...209].allSatisfy { $0.resolvedTransportMode == .automotive }, "A bus stop must not become walking")
require(ride[211...300].allSatisfy { $0.resolvedTransportMode == .walking }, "Do not keep the car hold after real walking resumes")
let boardingPending = processed(Array(bus.prefix(70)))
require(boardingPending.count == 70 && boardingPending.allSatisfy { $0.recordingEvidence?.captureExcluded == false },
        "Pending classification must never delete the start of a ride in all-movement mode")
let train: [GeoPoint] = (0...120).map { second -> GeoPoint in
    let time = Double(second)
    if second <= 30 { return point(time * 1.3, time) }
    let distance = 39.0 + Double(second - 30) * 20.0
    return point(distance, time, speed: 20)
}
let railway = processed(train)
require(railway[31...120].allSatisfy { $0.resolvedTransportMode == .automotive }, "Detect a train without Core Motion evidence")
let noSpeedTrain = train.map { original -> GeoPoint in
    var p = original; p.speed = -1; p.speedAccuracy = nil; p.reportedSpeedIsValid = false; return p
}
require(processed(noSpeedTrain)[31...120].allSatisfy { $0.resolvedTransportMode == .automotive },
        "Coherent sustained displacement must detect trains when reported speed is unavailable")
let wrongMotion = walking.map { original -> GeoPoint in
    var p = original; p.motionEvidence = motion(.automotive, at: 0); return p
}
require(processed(wrongMotion).allSatisfy { $0.resolvedTransportMode == .walking },
        "A car motion hint without corroborating displacement must not turn walking into driving")
let bike = (0...80).map { point(Double($0) * 5, Double($0), speed: 5, evidence: motion(.cycling, at: 0)) }
require(processed(bike).last?.resolvedTransportMode == .cycling, "Real cycling must remain detectable")
let stopped = (0...350).map { second -> GeoPoint in
    if second <= 100 { return point(Double(second) * 10, Double(second), speed: 10, evidence: motion(.automotive, at: 0)) }
    return point(1_000 + Double(second - 100) * 1.3, Double(second), evidence: nil)
}
require(processed(stopped).last?.resolvedTransportMode == .walking, "A car decision must not renew itself forever")
var lowQuality = walking
lowQuality[80].horizontalAccuracy = 140
require(RouteGeometry.observedPoints(from: processed(lowQuality)).allSatisfy { $0.pathBreakBefore != true },
        "A short rejected accuracy sample can reconnect only across a plausible short gap")
let gap = processed([point(0, 0), point(10, 10), point(300, 100), point(310, 110)])
require(RouteGeometry.observedPoints(from: gap).contains { $0.pathBreakBefore == true }, "Never invent roads across a real outage")
let line = (0...100).map { point(Double($0), Double($0)) }
let track = WalkTrack(rawPoints: line)
let range = start...start.addingTimeInterval(400)
let segments = RouteSegmentBuilder.build(tracks: [track], range: range)
require(segments.count == 100, "Every short connected edge must survive coarse road-frequency grouping")
let repeated = RouteSegmentBuilder.build(tracks: [track, track], range: range)
require(repeated.count == 100 && repeated.allSatisfy { $0.frequency == 2 }, "Repeated roads change frequency, not path completeness")
let empty = RouteSegmentBuilder.build(tracks: [track], range: start.addingTimeInterval(500)...start.addingTimeInterval(600))
require(empty.isEmpty, "Period filtering must not leave stale geometry")
let detour = [point(0, 0), point(50, 50, east: 150), point(100, 100)]
require(!RouteGeometry.isFaithful(detour, to: line), "Reject an unvisited directions detour")
require(RouteGeometry.isFaithful(line, to: line), "A matching observed route must pass")
let corner = [point(0, 0), point(0, 50, east: 100), point(100, 100, east: 100)]
require(!RouteGeometry.isFaithful([corner[0], corner[2]], to: corner), "Never cut across an observed corner")

if CommandLine.arguments.count > 1 {
    struct Archive: Codable { var tracks: [WalkTrack] }
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let originalData = try Data(contentsOf: url)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(Archive.self, from: originalData)
    let before = archive.tracks
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18))!
    let today = archive.tracks.filter { $0.startDate >= day && $0.startDate < day.addingTimeInterval(86_400) }
    require(today.count == 1, "Expect the reported walk in the local-only fixture")
    let raw = today[0].rawPoints
    let began = ProcessInfo.processInfo.systemUptime
    let revised = processed(raw)
    let revisedGeometry = RouteGeometry.observedPoints(from: revised)
    let seconds = ProcessInfo.processInfo.systemUptime - began
    require(zip(raw, revised).allSatisfy(sameSensors), "Do not alter any recorded GPS measurement")
    require(!RouteGeometry.isFaithful(today[0].matchedPoints, to: revisedGeometry), "The known phantom roads must fail the corridor check")
    require(revised.filter { $0.isUsableObservation }.allSatisfy { $0.resolvedTransportMode == .walking },
            "Today's short anomalous bursts must not produce vehicle sections in offline replay")
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let decoded = try decoder.decode(Archive.self, from: encoder.encode(archive))
    require(decoded.tracks == before, "Backward-compatible serialization must preserve all legacy records")
    let intact = try Data(contentsOf: url)
    require(intact == originalData && archive.tracks == before, "No retrospective file migration or sensor mutation")
    // Only aggregate metrics are printed. Never include coordinates or addresses.
    print(String(format: "Device replay PASS: %d observations, %d usable geometry points, %.3fs; archive unchanged",
                 raw.count, revisedGeometry.count, seconds))
}
print("PASS: walking/GPS bursts, spike rejection, bus boarding/alighting, train, bicycle, hold expiry, continuity, frequency, periods, route corridor, immutable sensor fields")
