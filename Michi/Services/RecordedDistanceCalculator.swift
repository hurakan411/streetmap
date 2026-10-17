import CoreLocation
import Foundation

/// Distance is a measurement, not the length of a directions-service result.
/// Recomputing from the untouched raw archive also repairs old records without
/// a destructive migration or overwriting their display geometry.
enum RecordedDistanceCalculator {
    struct Leg {
        let start: GeoPoint
        let end: GeoPoint
        let distance: CLLocationDistance
        var mode: TransportMode { end.resolvedTransportMode }
        var id: String { "\(start.id)|\(end.id)" }

        func overlap(with range: ClosedRange<Date>) -> (start: Date, end: Date, distance: Double)? {
            let lower = max(start.timestamp, range.lowerBound)
            let upper = min(end.timestamp, range.upperBound)
            guard lower < upper else { return nil }
            let fraction = upper.timeIntervalSince(lower) / end.timestamp.timeIntervalSince(start.timestamp)
            return (lower, upper, distance * fraction)
        }
    }

    struct Summary {
        var distance: CLLocationDistance = 0
        var activeDays = Set<Date>()
    }

    static func legs(from points: [GeoPoint], isEstimatedTrack: Bool = false) -> [Leg] {
        guard !isEstimatedTrack else { return [] }
        var result: [Leg] = []
        var anchor: GeoPoint?
        for point in points {
            // Do not bridge an unmeasured gap or a low-quality sample. Missing
            // distance is unknown; a guessed road route is not a measurement.
            let accuracyLimit = point.resolvedTransportMode == .walking ? 65.0 : 150.0
            guard !point.estimated,
                  CLLocationCoordinate2DIsValid(point.coordinate),
                  point.horizontalAccuracy.isFinite,
                  point.horizontalAccuracy >= 0, point.horizontalAccuracy <= accuracyLimit,
                  point.timestamp.timeIntervalSince1970.isFinite else {
                anchor = nil
                continue
            }
            guard let previous = anchor else { anchor = point; continue }
            let interval = point.timestamp.timeIntervalSince(previous.timestamp)
            guard interval > 0 else { continue }
            guard interval <= 180 else { anchor = point; continue }

            let distance = previous.location.distance(from: point.location)
            let uncertainty = max(5, min(35, (previous.horizontalAccuracy + point.horizontalAccuracy) * 0.5))
            // Keep the anchor for tiny changes so genuine slow movement can
            // accumulate, instead of discarding every short GPS step.
            if previous.speed <= 0.2, point.speed <= 0.2, distance <= uncertainty { continue }
            let minimumMovement = max(3, min(8,
                (previous.horizontalAccuracy + point.horizontalAccuracy) * 0.1))
            guard distance >= minimumMovement else { continue }

            // Only reject physically implausible jumps, not ordinary GPS
            // variation. Retain the last good anchor so a spike and its return
            // do not become two long legs. These are generous sanity limits,
            // not the user's transport-capture speed settings.
            let maximumSpeed: Double
            switch point.resolvedTransportMode {
            case .walking: maximumSpeed = 6
            case .cycling: maximumSpeed = 20
            case .automotive: maximumSpeed = 120
            }
            guard distance <= maximumSpeed * interval + uncertainty else { continue }
            result.append(Leg(start: previous, end: point, distance: distance))
            anchor = point
        }
        return result
    }

    static func summarize(tracks: [WalkTrack], livePoints: [GeoPoint] = [],
                          range: ClosedRange<Date>, modes: Set<TransportMode>,
                          calendar: Calendar = .autoupdatingCurrent) -> Summary {
        guard !modes.isEmpty else { return Summary() }
        var result = Summary()
        var seen = Set<String>()
        func add(_ legs: [Leg]) {
            for leg in legs {
                guard modes.contains(leg.mode), let overlap = leg.overlap(with: range),
                      seen.insert(leg.id).inserted else { continue }
                result.distance += overlap.distance
                var day = calendar.startOfDay(for: overlap.start)
                let lastDay = calendar.startOfDay(for: overlap.end.addingTimeInterval(-0.001))
                while day <= lastDay {
                    result.activeDays.insert(day)
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                    day = next
                }
            }
        }
        for track in tracks {
            add(legs(from: track.rawPoints, isEstimatedTrack: track.isEstimated == true))
        }
        // The finish callback can briefly expose the same GPS points in both
        // the saved archive and the live route; exact leg IDs prevent doubling.
        add(legs(from: livePoints))
        return result
    }
}
