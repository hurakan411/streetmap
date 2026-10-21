import CoreLocation
import Foundation
import MapKit

enum RouteGeometry {
    /// Geometry is independent of distance-stat noise suppression and road
    /// frequency buckets. In particular, short connected edges are not erased.
    static func observedPoints(from raw: [GeoPoint]) -> [GeoPoint] {
        var result: [GeoPoint] = []
        var previousIndex: Int?
        for (index, original) in raw.enumerated() where original.isUsableObservation {
            guard CLLocationCoordinate2DIsValid(original.coordinate),
                  original.horizontalAccuracy >= 0, original.horizontalAccuracy <= 100,
                  !original.estimated else { continue }
            var point = original
            if let last = result.last, let previousIndex {
                let duration = point.timestamp.timeIntervalSince(last.timestamp)
                guard duration > 0 else { continue }
                let skipped = index > previousIndex + 1
                let uncertainty = max(10, min(40, last.horizontalAccuracy + point.horizontalAccuracy))
                let speedLimit = point.resolvedTransportMode == .walking ? 4.0 : point.resolvedTransportMode == .cycling ? 15.0 : 100.0
                point.pathBreakBefore = duration > 45 || (skipped &&
                    (duration > 30 || last.location.distance(from: point.location) > speedLimit * duration + uncertainty))
            }
            result.append(point)
            previousIndex = index
        }
        return result
    }

    static func length(_ points: [GeoPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { sum, pair in
            sum + (pair.1.connects(from: pair.0) ? pair.0.location.distance(from: pair.1.location) : 0)
        }
    }

    static func isFaithful(_ proposed: [GeoPoint], to observed: [GeoPoint]) -> Bool {
        guard proposed.count > 1, observed.count > 1,
              !observed.dropFirst().contains(where: { $0.pathBreakBefore == true }),
              let a = proposed.first, let b = proposed.last,
              a.location.distance(from: observed[0].location) <= 25,
              b.location.distance(from: observed[observed.count - 1].location) <= 25 else { return false }
        let sourceLength = length(observed), proposedLength = length(proposed)
        guard proposedLength <= sourceLength * 1.25 + 15, proposedLength >= sourceLength * 0.75 else { return false }
        func inside(_ source: [GeoPoint], _ target: [GeoPoint]) -> Bool {
            let edges = target.map { MKMapPoint($0.coordinate) }
            for (a, b) in zip(source, source.dropFirst()) {
                let start = MKMapPoint(a.coordinate), end = MKMapPoint(b.coordinate)
                let count = max(1, Int(ceil(start.distance(to: end) / 10)))
                guard count <= 200 else { return false }
                let tolerance = max(12, min(30, max(a.horizontalAccuracy, b.horizontalAccuracy)))
                for index in 0...count {
                    let fraction = Double(index) / Double(count)
                    let p = MKMapPoint(x: start.x + fraction * (end.x - start.x), y: start.y + fraction * (end.y - start.y))
                    let scale = MKMetersPerMapPointAtLatitude(p.coordinate.latitude)
                    var within = false
                    for (a, b) in zip(edges, edges.dropFirst()) {
                        let dx = b.x - a.x, dy = b.y - a.y, denominator = dx * dx + dy * dy
                        let t = denominator > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / denominator)) : 0
                        if hypot(p.x - a.x - t * dx, p.y - a.y - t * dy) * scale <= tolerance { within = true; break }
                    }
                    if !within { return false }
                }
            }
            return true
        }
        return inside(proposed, observed) && inside(observed, proposed)
    }
}

enum RouteSegmentBuilder {
    /// Frequency is grouped approximately; visible geometry is not. Every
    /// distinct edge survives, even when adjacent edges share a road bucket.
    static func build(tracks: [WalkTrack], range: ClosedRange<Date>) -> [WeightedSegment] {
        struct Edge {
            var a: GeoPoint; var b: GeoPoint; var estimated: Bool
            var date: Date; var mode: TransportMode; var bucket: String
        }
        var counts: [String: Int] = [:]
        var geometry: [String: Edge] = [:]
        for track in tracks {
            var seen = Set<String>()
            let points = track.displayPoints
            for (a, b) in zip(points, points.dropFirst()) {
                guard b.connects(from: a), a.location.distance(from: b.location) >= 0.1 else { continue }
                let date = min(a.timestamp, b.timestamp)
                guard range.contains(date) else { continue }
                let mode = b.resolvedTransportMode
                let bucket = SegmentKey.make(a, b) + "|" + mode.rawValue
                if seen.insert(bucket).inserted { counts[bucket, default: 0] += 1 }
                func coordinateKey(_ p: GeoPoint) -> String {
                    "\(Int64((p.latitude * 10_000_000).rounded())):\(Int64((p.longitude * 10_000_000).rounded()))"
                }
                let ends = [coordinateKey(a), coordinateKey(b)].sorted()
                let key = ends.joined(separator: "|") + "|" + mode.rawValue
                let estimated = track.isEstimated == true || a.estimated || b.estimated
                if var previous = geometry[key] {
                    previous.date = min(previous.date, date)
                    previous.estimated = previous.estimated && estimated
                    geometry[key] = previous
                } else {
                    geometry[key] = Edge(a: a, b: b, estimated: estimated, date: date, mode: mode, bucket: bucket)
                }
            }
        }
        return geometry.map { key, edge in
            WeightedSegment(id: key, start: edge.a.coordinate, end: edge.b.coordinate,
                            frequency: counts[edge.bucket] ?? 1, isEstimated: edge.estimated,
                            firstVisitedAt: edge.date, transportMode: edge.mode)
        }.sorted { $0.firstVisitedAt == $1.firstVisitedAt ? $0.id < $1.id : $0.firstVisitedAt < $1.firstVisitedAt }
    }
}

/// Pure display preparation. The original geometry, frequency and stat rules
/// are preserved; callers may run this on a worker without touching the archive.
enum RouteDisplayPreparation {
    struct Result {
        let segments: [WeightedSegment]
        let signature: Int
        let stats: WalkStats
    }

    static func prepare(tracks: [WalkTrack], livePoints: [GeoPoint],
                        range: ClosedRange<Date>, modes: Set<TransportMode>,
                        calendar: Calendar, reusableSegments: [WeightedSegment]? = nil) -> Result? {
        guard !Task.isCancelled else { return nil }
        let segments = reusableSegments ?? RouteSegmentBuilder.build(
            tracks: tracks.filter { $0.endDate >= range.lowerBound && $0.startDate <= range.upperBound },
            range: range)
        guard !Task.isCancelled else { return nil }
        var signature = Hasher()
        // The builder already supplies a deterministic date/ID ordering.
        for segment in segments {
            signature.combine(segment.id)
            signature.combine(segment.start.latitude); signature.combine(segment.start.longitude)
            signature.combine(segment.end.latitude); signature.combine(segment.end.longitude)
            signature.combine(segment.frequency); signature.combine(segment.isEstimated)
            signature.combine(segment.firstVisitedAt); signature.combine(segment.transportMode)
        }
        guard !modes.isEmpty else {
            return Result(segments: segments, signature: signature.finalize(), stats: .zero)
        }
        let measured = RecordedDistanceCalculator.summarize(tracks: tracks, livePoints: livePoints,
            range: range, modes: modes, calendar: calendar)
        var firstSeen: [String: Date] = [:]
        var visibleKeys = Set<String>()
        for track in tracks.sorted(by: { $0.startDate < $1.startDate }) {
            guard !Task.isCancelled else { return nil }
            for (a, b) in zip(track.displayPoints, track.displayPoints.dropFirst()) {
                guard b.connects(from: a), modes.contains(b.resolvedTransportMode) else { continue }
                let key = SegmentKey.make(a, b)
                let date = min(a.timestamp, b.timestamp)
                if firstSeen[key] == nil { firstSeen[key] = date }
                guard range.contains(date), a.location.distance(from: b.location) >= 2 else { continue }
                visibleKeys.insert(key)
            }
        }
        let roads = visibleKeys.filter { firstSeen[$0].map(range.contains) ?? false }.count
        return Result(segments: segments, signature: signature.finalize(),
            stats: WalkStats(newRoads: roads, distance: measured.distance, activeDays: measured.activeDays.count))
    }
}
