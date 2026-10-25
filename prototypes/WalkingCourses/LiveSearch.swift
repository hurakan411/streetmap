// Standalone integration probe. Uses the production planner, but deliberately
// supplies no private recorded history. Coordinates are public station locations.
import Foundation
import CoreLocation
import MapKit

struct WalkTrack {
    let rawPoints: [ProbePoint] = []
    let isEstimated: Bool? = nil
}
struct ProbePoint {
    let coordinate: CLLocationCoordinate2D
    var location: CLLocation { CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude) }
}
enum ProbeMode { case walking, cycling }
enum RecordedDistanceCalculator {
    struct Leg { let mode: ProbeMode; let start: ProbePoint; let end: ProbePoint }
    static func legs(from: [ProbePoint], isEstimatedTrack: Bool) -> [Leg] { [] }
}

@main
struct LiveSearchProbe {
    static func main() async {
        let origin = CLLocationCoordinate2D(latitude: 35.6896, longitude: 139.7006)
        if CommandLine.arguments.contains("--leg") {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: CommandLine.arguments.contains("--new-york")
                ? .init(latitude: 40.77396, longitude: -73.97097) : origin))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CommandLine.arguments.contains("--new-york")
                ? .init(latitude: 40.7528, longitude: -73.97715) : .init(latitude: 35.6831, longitude: 139.7020)))
            request.transportType = .cycling
            request.requestsAlternateRoutes = true
            let directions = MKDirections(request: request)
            let deadline = Task { try await Task.sleep(nanoseconds: 18_000_000_000); directions.cancel() }
            defer { deadline.cancel() }
            do {
                let response = try await directions.calculate()
                for route in response.routes {
                    print("Cycling leg: type=\(route.transportType.rawValue), steps=\(Set(route.steps.map { $0.transportType.rawValue })), m=\(Int(route.distance)), min=\(route.expectedTravelTime / 60)")
                }
            } catch { print("Cycling leg unavailable: \(error)"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--offline") {
            await MainActor.run {
                let storage = RetainedWalkingCourseStorage(url: FileManager.default.temporaryDirectory
                    .appendingPathComponent("nonexistent-course-test-\(UUID()).json"))
                let planner = WalkingCoursePlanner(retentionStorage: storage)
                precondition(planner.travelMode == .walking)
                planner.setOrigin(origin, name: "Test")
                planner.generate(tracks: [], japanese: true)
                precondition(planner.isLoading)
                planner.setTravelMode(.cycling)
                precondition(!planner.isLoading && planner.courses.isEmpty && planner.errorMessage == nil)
                precondition(planner.travelMode == .cycling && planner.origin?.latitude == origin.latitude)
                let course = WalkingCourse(coordinates: [origin, origin], distance: 1000, seconds: 400,
                    unwalkedDistance: 500, score: 1, footprint: [], travelMode: .cycling)
                precondition(WalkingCourse(retained: course.retained).travelMode == .cycling)
                var legacy = course.retained
                legacy.travelMode = nil
                precondition(WalkingCourse(retained: legacy).travelMode == .walking)
                print("PASS: mode defaults, change cancels search, preserves start, saved cycling and legacy walking conversion")
            }
            return
        }
        let engine = WalkingCourseEngine()
        let work = Task {
            try await engine.propose(from: origin, minutes: 30, direction: .init(), tracks: [],
                travelMode: CommandLine.arguments.contains("--cycling") ? .cycling : .walking) {
                print($0 > WalkingCourseGeometry.maximumSearchTrials ? "Checking nearby places"
                    : "Checked candidate \($0)/\(WalkingCourseGeometry.maximumSearchTrials)")
                fflush(stdout)
            }
        }
        let timeout = Task {
            try await Task.sleep(nanoseconds: 100_000_000_000)
            work.cancel()
        }
        defer { timeout.cancel() }
        do {
            let courses = try await work.value
            guard !courses.isEmpty else { print("FAIL: No full-circle loop returned at public Shinjuku test location"); exit(1) }
            let frame = WalkingCourseGeometry.Footprint(coordinate: origin, walkingEdges: [])
            for course in courses {
                precondition(course.travelMode == (CommandLine.arguments.contains("--cycling") ? .cycling : .walking))
                let quality = WalkingCourseGeometry.loopQuality(course.coordinates, footprint: frame)
                guard quality.isAcceptable(forCycling: course.travelMode == .cycling) else { print("FAIL: Invalid loop returned"); exit(1) }
                print("PASS: \(Int(course.seconds / 60)) min, \(Int(course.distance)) m, retraced \(Int(quality.retracedFraction * 100))%")
            }
            print("PASS: Live MapKit full-circle search returned \(courses.count) usable loop(s)")
        } catch { print("Live MapKit search failed: \(error)"); exit(1) }
    }
}
