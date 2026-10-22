import Foundation
import MapKit

// Run on macOS to refresh the public, synthetic simulator fixture.
// Never pass a device history or a user's current location into this utility.
@main
struct GenerateSimulatorRoutes {
    static func main() async throws {
        if CommandLine.arguments.contains("--stroll") {
            try await generateStroll()
            return
        }
        let origin = CLLocationCoordinate2D(latitude: 35.6896, longitude: 139.7006)
        let names = [
            "西新宿五丁目駅", "中野坂上駅", "初台駅", "参宮橋駅",
            "千駄ヶ谷駅", "新宿御苑前駅", "四谷三丁目駅", "若松河田駅"
        ]
        var fixtures: [[String: Any]] = []
        for name in names {
            let search = MKLocalSearch.Request()
            search.naturalLanguageQuery = name
            search.region = MKCoordinateRegion(center: origin,
                latitudinalMeters: 8_000, longitudinalMeters: 8_000)
            let response = try await MKLocalSearch(request: search).start()
            guard let destination = response.mapItems.first,
                  CLLocation(latitude: origin.latitude, longitude: origin.longitude)
                    .distance(from: CLLocation(latitude: destination.placemark.coordinate.latitude,
                                              longitude: destination.placemark.coordinate.longitude)) < 5_000
            else { throw NSError(domain: "SimulatorFixture", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: "No nearby result: \(name)"]) }
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
            request.destination = destination
            request.transportType = .walking
            let directions = try await MKDirections(request: request).calculate()
            guard let route = directions.routes.min(by: { $0.distance < $1.distance })
            else { throw NSError(domain: "SimulatorFixture", code: 2) }
            let coordinates = (0..<route.polyline.pointCount).map { route.polyline.points()[$0].coordinate }
            fixtures.append([
                "name": name,
                "destination": destination.name ?? name,
                "distance": route.distance,
                "pointCount": coordinates.count,
                "polyline": encode(coordinates)
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: fixtures, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func generateStroll() async throws {
        // Public street anchors: Shinjuku 4/3-chome, Kabukicho's eastern edge,
        // Hanazono-jinja area, then the smaller blocks north of Shinjuku Gyoen.
        // Request actual walking geometry between each anchor, never join anchors directly.
        let anchors: [(Double, Double)] = [
            (35.6896, 139.7006),
            (35.6872, 139.7020), (35.6877, 139.7041), (35.6892, 139.7042),
            (35.6902, 139.7055), (35.6915, 139.7055), (35.6930, 139.7048),
            (35.6945, 139.7048), (35.6945, 139.7068), (35.6928, 139.7067),
            (35.6924, 139.7049), (35.6913, 139.7049), (35.6910, 139.7070),
            (35.6895, 139.7066), (35.6896, 139.7084), (35.6884, 139.7080),
            (35.6874, 139.7065), (35.6869, 139.7087), (35.6875, 139.7101),
            (35.6891, 139.7102), (35.6892, 139.7120), (35.6878, 139.7116),
            (35.68858, 139.70985)
        ]
        var coordinates: [CLLocationCoordinate2D] = []
        var totalDistance = 0.0
        for index in 1..<anchors.count {
            let source = coordinates.last ?? CLLocationCoordinate2D(
                latitude: anchors[0].0, longitude: anchors[0].1)
            let destination = CLLocationCoordinate2D(latitude: anchors[index].0, longitude: anchors[index].1)
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: source))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
            request.transportType = .walking
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.min(by: { $0.distance < $1.distance }) else {
                throw NSError(domain: "SimulatorFixture", code: 3)
            }
            let leg = (0..<route.polyline.pointCount).map { route.polyline.points()[$0].coordinate }
            guard let first = leg.first, let last = leg.last,
                  CLLocation(latitude: source.latitude, longitude: source.longitude).distance(
                    from: CLLocation(latitude: first.latitude, longitude: first.longitude)) < 15,
                  CLLocation(latitude: destination.latitude, longitude: destination.longitude).distance(
                    from: CLLocation(latitude: last.latitude, longitude: last.longitude)) < 100 else {
                throw NSError(domain: "SimulatorFixture", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "Disconnected walking leg \(index)"])
            }
            if coordinates.isEmpty {
                coordinates = leg
            } else {
                // The first point may be snapped a few metres along the same street.
                // Keep both points unless they are effectively identical.
                let join = CLLocation(latitude: source.latitude, longitude: source.longitude).distance(
                    from: CLLocation(latitude: first.latitude, longitude: first.longitude))
                coordinates.append(contentsOf: join < 0.5 ? Array(leg.dropFirst()) : leg)
            }
            totalDistance += route.distance
            FileHandle.standardError.write(Data("Walking leg \(index)/\(anchors.count - 1): \(Int(route.distance))m\n".utf8))
        }
        let fixture: [String: Any] = [
            "name": "新宿三丁目・花園神社周辺・新宿御苑前の寄り道散歩",
            "distance": totalDistance, "pointCount": coordinates.count,
            "legCount": anchors.count - 1, "polyline": encode(coordinates)
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func encode(_ coordinates: [CLLocationCoordinate2D]) -> String {
        var previousLatitude = 0
        var previousLongitude = 0
        var bytes: [UInt8] = []
        func append(_ delta: Int) {
            var value = delta < 0 ? ~(delta << 1) : delta << 1
            while value >= 0x20 {
                bytes.append(UInt8((0x20 | (value & 0x1f)) + 63))
                value >>= 5
            }
            bytes.append(UInt8(value + 63))
        }
        for coordinate in coordinates {
            let latitude = Int((coordinate.latitude * 100_000).rounded())
            let longitude = Int((coordinate.longitude * 100_000).rounded())
            append(latitude - previousLatitude)
            append(longitude - previousLongitude)
            previousLatitude = latitude
            previousLongitude = longitude
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
