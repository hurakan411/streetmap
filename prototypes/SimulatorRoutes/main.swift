import CoreLocation
import Foundation
import AppKit
typealias UIColor = NSColor

// Compile with the production SampleHistory enum extracted by the README command.
let now = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!
let tracks = SampleHistory.makeShinjuku(now: now)
precondition(tracks.count == 35, "Existing 27 routes plus 8 surrounding routes")
precondition(tracks.filter(\.isRoadMatched).count == 20)
precondition(tracks.allSatisfy { $0.endDate <= now }, "No future route timestamps")
precondition(tracks.allSatisfy(SampleHistory.isShinjukuPreviewSample), "All demo tracks must be replaced on relaunch")
let relaunched = tracks.filter { !SampleHistory.isShinjukuPreviewSample($0) } + SampleHistory.makeShinjuku(now: now)
precondition(relaunched.count == tracks.count, "No accumulated station branches on relaunch")

let expanded = Array(tracks.suffix(8))
let origin = SampleHistory.shinjukuLocation
let names = ["西新宿五丁目", "中野坂上", "初台", "参宮橋", "千駄ヶ谷", "新宿御苑前", "四谷三丁目", "若松河田"]
let expectedDistances = [1820.0, 2129, 1570, 1756, 1578, 5970, 1949, 2169]
let expectedPointCounts = [110, 68, 52, 69, 56, 358, 94, 107]
var coordinates: [GeoPoint] = []
for (index, track) in expanded.enumerated() {
    precondition(track.isRoadMatched && track.rawPoints == track.matchedPoints)
    precondition(track.rawPoints.count == expectedPointCounts[index])
    precondition(SampleHistory.isShinjukuPreviewSample(track), "Regenerated fixtures must replace saved samples")
    precondition(track.rawPoints.first!.location.distance(from: origin) < 25, "Route must join Shinjuku")
    var distance = 0.0
    for (a, b) in zip(track.rawPoints, track.rawPoints.dropFirst()) {
        let leg = a.location.distance(from: b.location)
        // MapKit legitimately uses a single segment for straight roads up to ~330m here.
        precondition(leg < 400, "Unexpected long straight jump")
        precondition(b.timestamp >= a.timestamp)
        // Different CoreLocation initializers can vary by millimetres; allow 5cm-scale timing noise.
        precondition(abs(b.timestamp.timeIntervalSince(a.timestamp) - leg / 1.25) < 0.05,
                     "\(names[index]): leg \(leg)m, elapsed \(b.timestamp.timeIntervalSince(a.timestamp))s at \(a.latitude),\(a.longitude) → \(b.latitude),\(b.longitude)")
        distance += leg
    }
    precondition((800...7_000).contains(distance))
    precondition(abs(distance - expectedDistances[index]) < expectedDistances[index] * 0.02)
    precondition(track.rawPoints.allSatisfy { $0.resolvedTransportMode == .walking && !$0.estimated })
    coordinates += track.rawPoints
    print("\(names[index]): \(track.rawPoints.count) points, \(Int(distance)) m")
}
let stroll = expanded[5]
precondition(stroll.rawPoints.count > 300, "Keep the detailed walking geometry")
precondition(stroll.endDate.timeIntervalSince(stroll.startDate) > 60 * 60, "A leisurely neighbourhood walk")
let strollCells = Set(stroll.rawPoints.map {
    "\(Int(($0.latitude * 2_000).rounded())):\(Int(($0.longitude * 2_000).rounded()))"
})
precondition(strollCells.count > 45, "Visit many distinct nearby street blocks")
precondition(coordinates.map(\.longitude).min()! < 139.685, "Expand west")
precondition(coordinates.map(\.longitude).max()! > 139.720, "Expand east")
precondition(coordinates.map(\.latitude).min()! < 35.681, "Expand south")
print("PASS: 35 simulator routes, eight connected road-aligned additions, valid dates and walking speeds")
