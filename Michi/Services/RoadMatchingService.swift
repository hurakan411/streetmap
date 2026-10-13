import CoreLocation
import MapKit

actor RoadMatchingService {
    static let shared = RoadMatchingService()

    func match(_ rawPoints: [GeoPoint]) async -> [GeoPoint] {
        let isEstimated = rawPoints.contains(where: \.estimated)
        let estimatedSpeed = representativeSpeed(of: rawPoints)
        let transportTypes = candidateTransportTypes(for: rawPoints, speed: estimatedSpeed)
        let anchors = makeAnchors(from: rawPoints, estimatedSpeed: estimatedSpeed)
        guard anchors.count >= 2 else { return rawPoints }

        var currentRun: [GeoPoint] = []
        var longestRun: [GeoPoint] = []
        let legCount = anchors.count - 1

        for pair in zip(anchors, anchors.dropFirst()) {
            guard !Task.isCancelled else { return rawPoints }
            let directDistance = pair.0.location.distance(from: pair.1.location)
            guard directDistance > 8 else { continue }

            var matchedRoute: MKRoute?
            for transportType in transportTypes {
                let request = MKDirections.Request()
                request.source = MKMapItem(placemark: MKPlacemark(coordinate: pair.0.coordinate))
                request.destination = MKMapItem(placemark: MKPlacemark(coordinate: pair.1.coordinate))
                request.transportType = transportType
                request.requestsAlternateRoutes = false

                do {
                    let response = try await MKDirections(request: request).calculate()
                    if let route = response.routes.min(by: { $0.distance < $1.distance }),
                       isPlausible(
                           route,
                           transportType: transportType,
                           directDistance: directDistance,
                           observedDuration: pair.1.timestamp.timeIntervalSince(pair.0.timestamp),
                           mode: pair.1.resolvedTransportMode
                       ) {
                        matchedRoute = route
                        break
                    }
                } catch {
                    continue
                }
            }
            // 一部の区間だけをつなぐと、失敗区間を直線で横切る不自然な線ができる。
            // 道路に沿った全区間を得られた場合だけ採用し、それ以外は元の軌跡へ戻す。
            guard let route = matchedRoute else {
                if currentRun.count > longestRun.count { longestRun = currentRun }
                currentRun = []
                continue
            }

            let coordinates = route.polyline.coordinates
            let duration = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
            for (index, coordinate) in coordinates.enumerated() {
                if let last = currentRun.last,
                   CLLocation(latitude: last.latitude, longitude: last.longitude)
                    .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) < 1 {
                    continue
                }
                let fraction = coordinates.count > 1 ? Double(index) / Double(coordinates.count - 1) : 0
                currentRun.append(GeoPoint(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    timestamp: pair.0.timestamp.addingTimeInterval(duration * fraction),
                    horizontalAccuracy: min(pair.0.horizontalAccuracy, pair.1.horizontalAccuracy),
                    speed: (pair.0.speed + pair.1.speed) / 2,
                    isEstimated: isEstimated,
                    transportMode: pair.0.resolvedTransportMode == pair.1.resolvedTransportMode
                        ? pair.0.resolvedTransportMode
                        : pair.1.resolvedTransportMode
                ))
            }
        }

        if currentRun.count > longestRun.count { longestRun = currentRun }
        return legCount > 0 && longestRun.count > 1 ? longestRun : rawPoints
    }

    private func candidateTransportTypes(
        for points: [GeoPoint],
        speed: CLLocationSpeed
    ) -> [MKDirectionsTransportType] {
        let modes = points.map(\.resolvedTransportMode)
        if modes.contains(.automotive) || speed >= 8 {
            // MapKitのtransitは経路ポリライン用途では正式対応していないため使わない。
            // 自動車経路として不自然ならmatchせず、元のGPS軌跡を維持する。
            return [.automobile]
        }
        return speed >= 4 ? [.automobile] : [.walking]
    }

    private func isPlausible(
        _ route: MKRoute,
        transportType: MKDirectionsTransportType,
        directDistance: CLLocationDistance,
        observedDuration: TimeInterval,
        mode: TransportMode
    ) -> Bool {
        let maximumRouteDistance: CLLocationDistance = transportType == .automobile
            ? max(1_200, directDistance * 2.25)
            : max(650, directDistance * 5)
        guard route.distance < maximumRouteDistance else { return false }

        // 実移動が自動車ETAより大幅に速い場合は高速鉄道の可能性が高い。
        // 道路へ無理に吸着させず、生のGPS軌跡へフォールバックする。
        if mode == .automotive,
           directDistance >= 1_000,
           observedDuration > 0,
           route.expectedTravelTime > observedDuration * 1.75 {
            return false
        }
        return true
    }

    private func representativeSpeed(of points: [GeoPoint]) -> CLLocationSpeed {
        let measured = points.map(\.speed).filter { $0 > 0 }
        if !measured.isEmpty {
            return measured.reduce(0, +) / Double(measured.count)
        }
        guard let first = points.first, let last = points.last else { return 0 }
        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        guard duration > 0 else { return 0 }
        return first.location.distance(from: last.location) / duration
    }

    private func makeAnchors(from points: [GeoPoint], estimatedSpeed: CLLocationSpeed) -> [GeoPoint] {
        guard let first = points.first else { return [] }
        var anchors = [first]
        var distanceSinceAnchor: CLLocationDistance = 0
        var previous = first
        let anchorDistance: CLLocationDistance = estimatedSpeed >= 4 ? 240 : 70

        for point in points.dropFirst() {
            distanceSinceAnchor += previous.location.distance(from: point.location)
            if distanceSinceAnchor >= anchorDistance {
                anchors.append(point)
                distanceSinceAnchor = 0
            }
            previous = point
        }
        if let last = points.last, anchors.last != last { anchors.append(last) }

        if anchors.count > 26 {
            let stride = Double(anchors.count - 1) / 25
            return (0...25).map { anchors[min(Int((Double($0) * stride).rounded()), anchors.count - 1)] }
        }
        return anchors
    }
}

private extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var buffer = Array(repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&buffer, range: NSRange(location: 0, length: pointCount))
        return buffer
    }
}
