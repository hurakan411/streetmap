import Foundation
import MapKit

let origin = CLLocationCoordinate2D(latitude: 35.69, longitude: 139.70)
func coordinate(_ x: Double, _ y: Double) -> CLLocationCoordinate2D {
    let radius = hypot(x, y)
    return WalkingCourseGeometry.waypoint(from: origin, meters: radius, bearing: atan2(x, y))
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print("FAIL: \(message)"); exit(1) }
}
let empty = WalkingCourseGeometry.Footprint(coordinate: origin, walkingEdges: [])
let points = [coordinate(0, 0), coordinate(0, 100), coordinate(100, 100), coordinate(100, 0), coordinate(0, 0)]
let novel = WalkingCourseGeometry.metrics(points, footprint: empty)
expect(abs(novel.total - 400) < 3, "Geometry length uses meters")
expect(abs(novel.unwalked - novel.total) < 0.01, "No history means no recorded walking overlap")
let recorded = WalkingCourseGeometry.Footprint(coordinate: origin, walkingEdges: [(points[0], points[1])])
let partial = WalkingCourseGeometry.metrics(points, footprint: recorded)
expect(partial.unwalked > 290 && partial.unwalked < 310, "Only parallel recorded section reduces new distance")
let reverse = WalkingCourseGeometry.metrics(Array(points.prefix(2).reversed()), footprint: recorded)
expect(reverse.unwalked < 1, "Walking opposite direction is already visited")
let perpendicular = WalkingCourseGeometry.metrics([coordinate(-30, 50), coordinate(30, 50)], footprint: recorded)
expect(perpendicular.unwalked > 59, "Crossing a recorded road is not the same street")
expect(novel.repeatFraction < 0.1, "An ordinary loop is not an out-and-back")
let outBack = WalkingCourseGeometry.metrics([coordinate(0, 0), coordinate(0, 500), coordinate(0, 0)], footprint: empty)
expect(outBack.repeatFraction > 0.35, "Out-and-back carries a large repeat penalty")
let squareQuality = WalkingCourseGeometry.loopQuality(points, footprint: empty)
expect(squareQuality.isAcceptable, "A genuine closed block is accepted")
expect(!WalkingCourseGeometry.loopQuality([coordinate(0, 0), coordinate(0, 500), coordinate(0, 0)], footprint: empty).isAcceptable,
    "Closing at the origin alone does not make an out-and-back a loop")
let lollipop = [coordinate(0, 0), coordinate(0, 400), coordinate(400, 400), coordinate(400, 800),
                coordinate(0, 800), coordinate(0, 400), coordinate(0, 0)]
let lollipopQuality = WalkingCourseGeometry.loopQuality(lollipop, footprint: empty)
expect(!lollipopQuality.isAcceptable && lollipopQuality.longestReusedRun > 300,
    "A large shared access road is rejected even if the far end makes a loop")
let shortAccess = [coordinate(0, 0), coordinate(0, 20), coordinate(200, 20), coordinate(200, 220),
                   coordinate(0, 220), coordinate(0, 20), coordinate(0, 0)]
expect(WalkingCourseGeometry.loopQuality(shortAccess, footprint: empty).isAcceptable,
    "A short unavoidable start access is allowed")
let spur = [coordinate(0, 0), coordinate(0, 300), coordinate(200, 300), coordinate(200, 180),
            coordinate(200, 300), coordinate(300, 300), coordinate(300, 0), coordinate(0, 0)]
expect(!WalkingCourseGeometry.loopQuality(spur, footprint: empty).isAcceptable,
    "A long out-and-back spur inside a loop is rejected")
let smallSpur = [coordinate(0, 0), coordinate(0, 300), coordinate(200, 300), coordinate(200, 260),
                 coordinate(200, 300), coordinate(300, 300), coordinate(300, 0), coordinate(0, 0)]
expect(!WalkingCourseGeometry.loopQuality(smallSpur, footprint: empty).isAcceptable,
    "Even a shorter internal waypoint detour must not masquerade as a circuit")
let offsetReturn = [coordinate(0, 0), coordinate(0, 500), coordinate(4, 500), coordinate(4, 0), coordinate(0, 0)]
expect(!WalkingCourseGeometry.loopQuality(offsetReturn, footprint: empty).isAcceptable,
    "A few meters of geometry offset does not disguise the return trip")
let parallelStreets = [coordinate(0, 0), coordinate(0, 500), coordinate(24, 500), coordinate(24, 0), coordinate(0, 0)]
expect(WalkingCourseGeometry.loopQuality(parallelStreets, footprint: empty).isAcceptable,
    "Distinct parallel streets can form a valid loop")
let crossing = [coordinate(-100, 0), coordinate(100, 0), coordinate(100, 100), coordinate(0, 100), coordinate(0, -100)]
expect(WalkingCourseGeometry.loopQuality(crossing, footprint: empty).reusedMeters < 1,
    "Crossing another section at a right angle is not street reuse")
let openPath = [coordinate(0, 0), coordinate(0, 200), coordinate(200, 200)]
expect(!WalkingCourseGeometry.loopQuality(openPath, footprint: empty).isAcceptable, "An open path cannot be a loop")
expect(!WalkingCourseGeometry.loopQuality([], footprint: empty).isAcceptable, "Empty loop rejected safely")
var denseSquare: [CLLocationCoordinate2D] = []
for (a, b) in [(WalkingCourseGeometry.XY(x: 0, y: 0), WalkingCourseGeometry.XY(x: 0, y: 100)),
               (.init(x: 0, y: 100), .init(x: 100, y: 100)),
               (.init(x: 100, y: 100), .init(x: 100, y: 0)),
               (.init(x: 100, y: 0), .init(x: 0, y: 0))] {
    for step in 0..<100 {
        let t = Double(step) / 100
        denseSquare.append(coordinate(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
    }
}
denseSquare.append(coordinate(0, 0))
expect(WalkingCourseGeometry.loopQuality(denseSquare, footprint: empty).isAcceptable,
    "Loop acceptance is stable with densely sampled geometry")
expect(WalkingCourseGeometry.metrics([], footprint: empty).total == 0, "Empty geometry is safe")
expect(WalkingCourseGeometry.similarity(novel.cells, novel.cells) == 1, "Identical candidates deduplicate")
expect(WalkingCourseGeometry.similarity([], []) == 0, "Empty coverage is safe")
let waypoint = WalkingCourseGeometry.waypoint(from: origin, meters: 500, bearing: 0)
let actual = CLLocation(latitude: origin.latitude, longitude: origin.longitude).distance(from: CLLocation(latitude: waypoint.latitude, longitude: waypoint.longitude))
expect(abs(actual - 500) < 3, "Waypoint projection uses meters, not degrees")
let wrapped = WalkingCourseGeometry.Direction(bearing: -10, opening: 120)
expect(wrapped.bearing == 350 && wrapped.opening == 120, "Direction normalizes bearing and supports a wide sector")
expect(WalkingCourseGeometry.Direction().opening == 360, "Default searches every direction")
expect(WalkingCourseGeometry.Direction(opening: 400).opening == 360, "Opening caps at 360 degrees")
expect(WalkingCourseGeometry.Direction(opening: .nan).opening == 360, "Invalid opening defaults to full circle")
for angle in stride(from: 0.0, to: 360, by: 1) {
    expect(WalkingCourseGeometry.Direction().contains(angle), "Full circle contains all bearings")
}
expect(WalkingCourseGeometry.Direction(bearing: 355, opening: 30).contains(5), "Sector wraps across north")
expect(!WalkingCourseGeometry.Direction(bearing: 355, opening: 30).contains(90), "Direction excludes other compass regions")
expect(WalkingCourseGeometry.Direction(bearing: 0, opening: -5).opening == 0, "A sector can close to zero")
for bearing in stride(from: 0.0, to: 360.0, by: 45) {
    for opening in [10.0, 30.0, 60.0, 90.0, 120, 180, 270, 359, 360] {
        let direction = WalkingCourseGeometry.Direction(bearing: bearing, opening: opening)
        for attempt in 0..<8 {
            let waypoints = WalkingCourseGeometry.directionalWaypoints(origin: origin, distance: 2_000,
                direction: direction, attempt: attempt, scale: 1)
            expect(waypoints.count == 2, "Two loop waypoints")
            expect(CLLocation(latitude: waypoints[0].latitude, longitude: waypoints[0].longitude)
                .distance(from: CLLocation(latitude: waypoints[1].latitude, longitude: waypoints[1].longitude)) > 10,
                "Wide-angle waypoints do not collapse into a coincident pair")
            for point in waypoints {
                expect(direction.contains(WalkingCourseGeometry.bearing(from: origin, to: point), tolerance: 0.01),
                    "Every generated waypoint stays in the chosen sector")
            }
        }
    }
}
let cleaned = WalkingCourseGeometry.removingWaypointSpurs(smallSpur, footprint: empty)
expect(cleaned.count < smallSpur.count && WalkingCourseGeometry.loopQuality(cleaned, footprint: empty).isAcceptable,
    "Short dead-end waypoint spur is removed to recover a genuine circuit")
expect(WalkingCourseGeometry.removingWaypointSpurs(points, footprint: empty).count == points.count,
    "Real loop is not erased")
expect(WalkingCourseGeometry.removingWaypointSpurs(lollipop, footprint: empty).count == lollipop.count,
    "Large shared stem is not removed or disguised")
expect(cleaned.first!.latitude == smallSpur.first!.latitude && cleaned.last!.latitude == smallSpur.last!.latitude,
    "Cleaning preserves start and finish")
expect(cleaned.allSatisfy { point in smallSpur.contains { $0.latitude == point.latitude && $0.longitude == point.longitude } },
    "Cleaning never invents coordinates")
expect(WalkingCourseGeometry.directionFraction(points, footprint: empty, direction: .init()) == 1,
    "All directions does not filter loops near the start")
let north = [coordinate(0, 100), coordinate(0, 300)]
expect(WalkingCourseGeometry.directionFraction(north, footprint: empty, direction: .init(bearing: 0, opening: 30)) > 0.99,
    "Route length in selected direction is rewarded")
expect(WalkingCourseGeometry.directionFraction(north, footprint: empty, direction: .init(bearing: 180, opening: 30)) < 0.01,
    "Opposite route is rejected")
print("PASS: novelty, all-new/partial/reverse/perpendicular overlap, loops vs out-and-back, deduplication, empty input and waypoint distance")
print("PASS: 576 directional triangle cases including 360 degrees, angle wraparound, opening limits and route direction scoring")
print("PASS: short waypoint spur removal preserves genuine circuits, endpoints and existing road geometry")
print("PASS: loop quality (closed blocks, shared starts, lollipops, spurs, offset returns, parallel roads, crossings, dense samples)")

let rideWithMinorOverlap = [coordinate(0, 0), coordinate(0, 1500), coordinate(1000, 1500),
    coordinate(1000, 1460), coordinate(1000, 1500), coordinate(1500, 1500), coordinate(1500, 0), coordinate(0, 0)]
let rideQuality = WalkingCourseGeometry.loopQuality(rideWithMinorOverlap, footprint: empty)
expect(rideQuality.isAcceptable(forCycling: true), "A 40m overlap does not discard a 6km cycling circuit")
expect(!rideQuality.isAcceptable, "Walking keeps its stricter internal-overlap policy")
for bad in [lollipop, offsetReturn, [coordinate(0, 0), coordinate(0, 2000), coordinate(0, 0)]] {
    expect(!WalkingCourseGeometry.loopQuality(bad, footprint: empty).isAcceptable(forCycling: true),
        "Cycling still rejects lollipops, thin return corridors and pure out-and-backs")
}
let rideWithLongSpur = [coordinate(0, 0), coordinate(0, 1500), coordinate(1000, 1500),
    coordinate(1000, 1200), coordinate(1000, 1500), coordinate(1500, 1500), coordinate(1500, 0), coordinate(0, 0)]
expect(!WalkingCourseGeometry.loopQuality(rideWithLongSpur, footprint: empty).isAcceptable(forCycling: true),
    "A 300m repeated spur is still too long even in a large ride")
let targets = [coordinate(1000, 1500), coordinate(1500, 1500)]
for retry in 0..<2 {
    let sector = WalkingCourseGeometry.Direction(bearing: 40, opening: 70)
    let repaired = WalkingCourseGeometry.repairWaypoints(targets, quality: rideQuality,
        footprint: empty, direction: sector, retry: retry)
    expect(repaired != nil && repaired!.count == 2, "Overlap creates a bounded two-waypoint repair")
    expect(zip(targets, repaired!).filter { empty.project($0.0).distance(to: empty.project($0.1)) > 1 }.count == 1,
        "Only the waypoint nearest the overlap is adjusted")
    for point in repaired! {
        expect(sector.contains(WalkingCourseGeometry.bearing(from: origin, to: point), tolerance: 0.1),
            "Repair preserves the selected direction sector")
    }
}
expect(WalkingCourseGeometry.repairWaypoints(points, quality: squareQuality, footprint: empty, direction: .init(), retry: 0) == nil,
    "Malformed waypoint counts are not repaired")
expect(WalkingCourseGeometry.durationIsUsable(19 * 60, target: 30 * 60), "Slightly short alternatives remain available")
expect(WalkingCourseGeometry.durationIsUsable(46 * 60, target: 30 * 60), "Slightly long alternatives remain available")
expect(!WalkingCourseGeometry.durationIsPreferred(46 * 60, target: 30 * 60), "Long alternatives rank behind close-duration loops")
expect(WalkingCourseGeometry.durationIsPreferred(31 * 60, target: 30 * 60), "Close-duration loops are preferred")
expect(!WalkingCourseGeometry.durationIsUsable(3 * 60, target: 30 * 60), "Wildly wrong durations still rejected")
expect(!WalkingCourseGeometry.durationIsUsable(.infinity, target: 30 * 60), "Invalid duration rejected")
expect(!WalkingCourseGeometry.durationIsUsable(1800, target: 0), "Zero target duration rejected")
print("PASS: cycling proportional overlap, long-spur rejection, sector-constrained corridor repairs and duration ranking policy")
