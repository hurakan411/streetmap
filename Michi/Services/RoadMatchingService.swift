import CoreLocation
import MapKit

actor RoadMatchingService {
    static let shared = RoadMatchingService()
    private var cache: [Int: [GeoPoint]] = [:]

    func match(_ rawPoints: [GeoPoint]) async -> [GeoPoint] {
        // Route planning must never manufacture roads across an unobserved gap.
        guard !rawPoints.contains(where: \.estimated) else { return [] }
        let observed = RouteGeometry.observedPoints(from: rawPoints)
        guard observed.count > 1 else { return observed }
        var result = [observed[0]]
        var start = 0
        var distance = 0.0
        var requestCount = 0
        for end in 1..<observed.count {
            guard !Task.isCancelled else { return observed }
            let point = observed[end]
            if point.pathBreakBefore == true {
                if start < end - 1 { result.append(contentsOf: observed[(start + 1)..<end]) }
                result.append(point)
                start = end; distance = 0
                continue
            }
            distance += observed[end - 1].location.distance(from: point.location)
            let mode = observed[start].resolvedTransportMode
            let modeChanged = point.resolvedTransportMode != mode
            guard distance >= (mode == .walking ? 70 : 180) || modeChanged || end == observed.count - 1 else { continue }
            let leg = Array(observed[start...end])
            var hasher = Hasher()
            for p in leg { hasher.combine(p.id); hasher.combine(p.resolvedTransportMode) }
            let key = hasher.finalize()
            var replacement = cache[key] ?? leg
            if cache[key] == nil && requestCount < 16 && distance >= 15 && !modeChanged {
                requestCount += 1
                let request = MKDirections.Request()
                request.source = MKMapItem(placemark: MKPlacemark(coordinate: leg[0].coordinate))
                request.destination = MKMapItem(placemark: MKPlacemark(coordinate: point.coordinate))
                request.transportType = mode == .automotive ? .automobile : .walking
                request.requestsAlternateRoutes = false
                let directions = MKDirections(request: request)
                let response = try? await withTaskCancellationHandler {
                    try await directions.calculate()
                } onCancel: {
                    directions.cancel()
                }
                if let route = response?.routes.min(by: { $0.distance < $1.distance }) {
                    var proposed = interpolate(route.polyline, from: leg[0], to: point)
                    if RouteGeometry.isFaithful(proposed, to: leg) {
                        // Keep the original endpoints so adjacent legs join exactly.
                        proposed[0] = leg[0]
                        proposed[proposed.count - 1] = point
                        replacement = proposed
                    }
                }
                if cache.count >= 2_000 { cache.removeAll() }
                cache[key] = replacement
            }
            result.append(contentsOf: replacement.dropFirst())
            start = end; distance = 0
        }
        return result
    }

    private func interpolate(_ line: MKPolyline, from start: GeoPoint, to end: GeoPoint) -> [GeoPoint] {
        var coordinates = Array(repeating: kCLLocationCoordinate2DInvalid, count: line.pointCount)
        line.getCoordinates(&coordinates, range: NSRange(location: 0, length: line.pointCount))
        guard coordinates.count >= 2 else { return [] }
        var distances = [0.0]
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            distances.append(distances.last! + MKMapPoint(a).distance(to: MKMapPoint(b)))
        }
        let length = max(1, distances.last!)
        let duration = end.timestamp.timeIntervalSince(start.timestamp)
        return coordinates.enumerated().map { index, coordinate in
            GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude,
                     timestamp: start.timestamp.addingTimeInterval(duration * distances[index] / length),
                     horizontalAccuracy: max(start.horizontalAccuracy, end.horizontalAccuracy),
                     speed: max(0, (start.speed + end.speed) / 2), transportMode: end.resolvedTransportMode)
        }
    }
}
