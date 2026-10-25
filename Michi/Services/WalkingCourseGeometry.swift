import CoreLocation
import MapKit

/// Temporary planning geometry. Nothing here is written to recorded history.
enum WalkingCourseGeometry {
    static let maximumSearchTrials = 10
    static func durationIsUsable(_ seconds: Double, target: Double) -> Bool {
        seconds.isFinite && target.isFinite && target > 0 && seconds / target >= 0.5 && seconds / target <= 1.7
    }
    static func durationIsPreferred(_ seconds: Double, target: Double) -> Bool {
        seconds.isFinite && target.isFinite && target > 0 && seconds / target >= 0.75 && seconds / target <= 1.3
    }
    struct Direction: Equatable, Sendable {
        var bearing: Double
        var opening: Double
        init(bearing: Double = 0, opening: Double = 360) {
            self.bearing = Self.normalized(bearing)
            self.opening = min(360, max(0, opening.isFinite ? opening : 360))
        }
        static func normalized(_ angle: Double) -> Double {
            guard angle.isFinite else { return 0 }
            return (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        }
        func contains(_ angle: Double, tolerance: Double = 0) -> Bool {
            abs(Self.delta(angle, bearing)) <= opening / 2 + tolerance
        }
        static func delta(_ a: Double, _ b: Double) -> Double {
            (normalized(a - b) + 180).truncatingRemainder(dividingBy: 360) - 180
        }
    }

    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let latA = a.latitude * .pi / 180, latB = b.latitude * .pi / 180
        let deltaLon = (b.longitude - a.longitude) * .pi / 180
        return Direction.normalized(atan2(sin(deltaLon) * cos(latB),
            cos(latA) * sin(latB) - sin(latA) * cos(latB) * cos(deltaLon)) * 180 / .pi)
    }

    static func directionalWaypoints(origin: CLLocationCoordinate2D, distance: Double, direction: Direction,
                                     attempt: Int, scale: Double) -> [CLLocationCoordinate2D] {
        let offsets = [0.0, -0.8, 0.8, -0.4, 0.4, -1.0, 1.0, 0.15]
        let widths = [0.92, 0.62, 0.62, 0.80, 0.80, 0.50, 0.70, 0.90]
        let radii = [1.0, 0.94, 1.08, 1.12, 0.88, 1.0, 0.85, 1.05]
        let i = min(7, max(0, attempt))
        // A full-circle search explores distinct compass regions, rather than
        // degenerating into two coincident waypoints at +/-180 degrees.
        let fullBearings = [0.0, 90, 180, 270, 45, 135, 225, 315]
        let span = min(120, direction.opening * widths[i])
        let half = span * .pi / 360
        let middleDegrees = direction.opening == 360 ? direction.bearing + fullBearings[i]
            : direction.bearing + (direction.opening - span) / 2 * offsets[i]
        let middle = middleDegrees * .pi / 180
        let radius = distance / ((2 + 2 * sin(max(0.01, half))) * 1.35) * scale * radii[i]
        return [waypoint(from: origin, meters: radius, bearing: middle - half),
                waypoint(from: origin, meters: radius * (i == 5 ? 0.8 : 1), bearing: middle + half)]
    }

    static func directionFraction(_ coordinates: [CLLocationCoordinate2D], footprint: Footprint, direction: Direction) -> Double {
        if direction.opening == 360 { return coordinates.count > 1 ? 1 : 0 }
        let points = coordinates.map(footprint.project)
        var inside = 0.0, total = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let length = a.distance(to: b)
            guard length > 0, length.isFinite else { continue }
            let count = max(1, Int(ceil(length / 20)))
            for index in 0..<count {
                let t = (Double(index) + 0.5) / Double(count)
                let p = XY(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                // The first/last street at the origin may point away from the
                // selected sector. Ignore this small access corridor.
                if hypot(p.x, p.y) < 80 { continue }
                let angle = Direction.normalized(atan2(p.x, -p.y) * 180 / .pi)
                total += length / Double(count)
                if direction.contains(angle, tolerance: 8) { inside += length / Double(count) }
            }
        }
        return total > 0 ? inside / total : 0
    }
    struct XY: Hashable, Sendable {
        var x: Double
        var y: Double
        func distance(to other: XY) -> Double { hypot(x - other.x, y - other.y) }
    }
    struct Cell: Hashable, Sendable { let x: Int; let y: Int }
    struct Edge: Sendable { let a: XY; let b: XY }
    struct Footprint: Sendable {
        let origin: XY
        let metersPerPoint: Double
        private var cells: [Cell: [Edge]] = [:]

        init(coordinate: CLLocationCoordinate2D, walkingEdges: [(CLLocationCoordinate2D, CLLocationCoordinate2D)]) {
            let point = MKMapPoint(coordinate)
            origin = XY(x: point.x, y: point.y)
            metersPerPoint = MKMetersPerMapPointAtLatitude(coordinate.latitude)
            for (a, b) in walkingEdges {
                let edge = Edge(a: project(a), b: project(b))
                guard edge.a.distance(to: edge.b) <= 300 else { continue }
                let minX = Int(floor((min(edge.a.x, edge.b.x) - 20) / 40))
                let maxX = Int(floor((max(edge.a.x, edge.b.x) + 20) / 40))
                let minY = Int(floor((min(edge.a.y, edge.b.y) - 20) / 40))
                let maxY = Int(floor((max(edge.a.y, edge.b.y) + 20) / 40))
                for x in minX...maxX { for y in minY...maxY {
                    cells[Cell(x: x, y: y), default: []].append(edge)
                } }
            }
        }

        func project(_ coordinate: CLLocationCoordinate2D) -> XY {
            let p = MKMapPoint(coordinate)
            return XY(x: (p.x - origin.x) * metersPerPoint, y: (p.y - origin.y) * metersPerPoint)
        }

        func coordinate(_ point: XY) -> CLLocationCoordinate2D {
            MKMapPoint(x: origin.x + point.x / metersPerPoint, y: origin.y + point.y / metersPerPoint).coordinate
        }

        func wasWalked(_ p: XY, direction: XY) -> Bool {
            let nearby = cells[Cell(x: Int(floor(p.x / 40)), y: Int(floor(p.y / 40)))] ?? []
            return nearby.contains { edge in
                let dx = edge.b.x - edge.a.x, dy = edge.b.y - edge.a.y
                let length = hypot(dx, dy) * hypot(direction.x, direction.y)
                guard length > 0, abs(dx * direction.x + dy * direction.y) / length > 0.7 else { return false }
                return WalkingCourseGeometry.distance(p, to: edge) <= 20
            }
        }
    }

    struct Metrics: Sendable {
        var total = 0.0
        var unwalked = 0.0
        var repeated = 0.0
        var cells = Set<Cell>()
        var repeatFraction: Double { repeated / max(total, 1) }
    }

    static func distance(_ p: XY, to edge: Edge) -> Double {
        let dx = edge.b.x - edge.a.x, dy = edge.b.y - edge.a.y
        let square = dx * dx + dy * dy
        guard square > 0 else { return p.distance(to: edge.a) }
        let t = min(1, max(0, ((p.x - edge.a.x) * dx + (p.y - edge.a.y) * dy) / square))
        return p.distance(to: XY(x: edge.a.x + t * dx, y: edge.a.y + t * dy))
    }

    static func metrics(_ coordinates: [CLLocationCoordinate2D], footprint: Footprint) -> Metrics {
        let points = coordinates.map(footprint.project)
        var result = Metrics()
        var lastSeen: [Cell: Int] = [:]
        var sampleIndex = 0
        var previousCell: Cell?
        var isRepeatedVisit = false
        for (a, b) in zip(points, points.dropFirst()) {
            let length = a.distance(to: b)
            guard length > 0, length.isFinite else { continue }
            let count = max(1, Int(ceil(length / 12)))
            for step in 0..<count {
                let t = (Double(step) + 0.5) / Double(count)
                let p = XY(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                let cell = Cell(x: Int(floor(p.x / 24)), y: Int(floor(p.y / 24)))
                let part = length / Double(count)
                result.total += part
                if !footprint.wasWalked(p, direction: XY(x: b.x - a.x, y: b.y - a.y)) { result.unwalked += part }
                if previousCell != cell {
                    isRepeatedVisit = lastSeen[cell].map { sampleIndex - $0 > 5 } ?? false
                    previousCell = cell
                }
                if isRepeatedVisit { result.repeated += part }
                lastSeen[cell] = sampleIndex
                result.cells.insert(cell)
                sampleIndex += 1
            }
        }
        return result
    }

    struct LoopQuality {
        let total: Double
        /// Count a reused street twice: its outward AND return traversal.
        let reusedMeters: Double
        let longestReusedRun: Double
        let interiorReusedMeters: Double
        let area: Double
        let closure: Double
        var repairEdge: Edge? = nil
        var retracedFraction: Double { min(1, 2 * reusedMeters / max(1, total)) }
        var normalizedArea: Double { area / max(1, total * total) }
        var isAcceptable: Bool {
            isAcceptable(forCycling: false)
        }
        func isAcceptable(forCycling: Bool) -> Bool {
            // A 6km ride must not fail for a 15m junction overlap. Bound both
            // its fraction and continuous length; long out-and-backs still fail.
            let runLimit = forCycling ? max(45, min(180, total * 0.03)) : max(30, min(80, total * 0.04))
            let interiorLimit = forCycling ? max(18, min(180, total * 0.03)) : 12
            return total > 300 && closure <= 35 && retracedFraction <= 0.12
                && longestReusedRun <= runLimit
                && interiorReusedMeters <= interiorLimit
                && area >= 2_000 && normalizedArea >= 0.004
        }
    }

    /// Shift the waypoint nearest an overlapping corridor perpendicular to it.
    /// These are request targets only: Apple must route every leg again. No
    /// straight-line shortcut is ever substituted into a displayed course.
    static func repairWaypoints(_ waypoints: [CLLocationCoordinate2D], quality: LoopQuality,
                                footprint: Footprint, direction: Direction, retry: Int) -> [CLLocationCoordinate2D]? {
        guard waypoints.count == 2, let edge = quality.repairEdge else { return nil }
        let dx = edge.b.x - edge.a.x, dy = edge.b.y - edge.a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        let middle = XY(x: (edge.a.x + edge.b.x) / 2, y: (edge.a.y + edge.b.y) / 2)
        let projected = waypoints.map(footprint.project)
        let index = projected[0].distance(to: middle) < projected[1].distance(to: middle) ? 0 : 1
        let side = retry % 2 == 0 ? 1.0 : -1.0
        let shift = max(65, min(280, quality.total * 0.045))
        var moved = XY(x: projected[index].x - dy / length * shift * side,
                       y: projected[index].y + dx / length * shift * side)
        var angle = Direction.normalized(atan2(moved.x, -moved.y) * 180 / .pi)
        if !direction.contains(angle) {
            let delta = Direction.delta(angle, direction.bearing)
            angle = direction.bearing + min(direction.opening / 2, max(-direction.opening / 2, delta))
            let radius = hypot(moved.x, moved.y)
            moved = XY(x: sin(angle * .pi / 180) * radius, y: -cos(angle * .pi / 180) * radius)
        }
        guard moved.distance(to: projected[index]) >= 25 else { return nil }
        var repaired = waypoints
        repaired[index] = footprint.coordinate(moved)
        return repaired
    }

    /// Remove short dead-end excursions caused by a waypoint snapped beyond a
    /// junction. Only exactly revisited vertices are joined: no invented roads,
    /// no clipping a large real circuit or the start's access street.
    static func removingWaypointSpurs(_ coordinates: [CLLocationCoordinate2D], footprint: Footprint) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 3 else { return coordinates }
        let points = coordinates.map(footprint.project)
        let total = zip(points, points.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        var kept: [Int] = [], removed = 0.0
        for i in coordinates.indices {
            if let match = kept.lastIndex(where: { j in
                j > 0 && i < coordinates.count - 1
                    && coordinates[j].latitude == coordinates[i].latitude
                    && coordinates[j].longitude == coordinates[i].longitude
            }), match < kept.count - 1 {
                let excursion = Array(kept[match...]) + [i]
                let length = zip(excursion, excursion.dropFirst()).reduce(0.0) { $0 + points[$1.0].distance(to: points[$1.1]) }
                let area = abs(zip(excursion, excursion.dropFirst()).reduce(0.0) {
                    $0 + points[$1.0].x * points[$1.1].y - points[$1.1].x * points[$1.0].y
                }) / 2
                if length <= 300, removed + length <= total * 0.20, area < 50 {
                    removed += length
                    kept.removeSubrange((match + 1)...)
                    continue
                }
            }
            kept.append(i)
        }
        return kept.map { coordinates[$0] }
    }

    /// Unlike coverage cells, this compares actual nearby line segments and
    /// their headings. Crossing streets and distinct parallel streets are not
    /// automatically counted as the same road merely because they share a cell.
    static func loopQuality(_ coordinates: [CLLocationCoordinate2D], footprint: Footprint) -> LoopQuality {
        let points = coordinates.map(footprint.project)
        struct Sample {
            let edge: Edge
            let along: Double
        }
        var index: [Cell: [Sample]] = [:]
        let pathLength = zip(points, points.dropFirst()).reduce(0.0) {
            let length = $1.0.distance(to: $1.1)
            return $0 + (length.isFinite ? length : 0)
        }
        let accessAllowance = max(30, min(80, pathLength * 0.04))
        var total = 0.0, reused = 0.0, interiorReuse = 0.0, longest = 0.0, run = 0.0, gap = 0.0
        var repairEdge: Edge?
        var longestInteriorRun = 0.0
        let tolerance = 6.0
        for (a, b) in zip(points, points.dropFirst()) {
            let length = a.distance(to: b)
            guard length.isFinite, length > 0 else { continue }
            let count = max(1, Int(ceil(length / 10)))
            let part = length / Double(count)
            for step in 0..<count {
                func point(_ t: Double) -> XY {
                    XY(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                }
                let edge = Edge(a: point(Double(step) / Double(count)), b: point(Double(step + 1) / Double(count)))
                let middle = point((Double(step) + 0.5) / Double(count))
                let cell = Cell(x: Int(floor(middle.x / 20)), y: Int(floor(middle.y / 20)))
                let along = total + part / 2
                let overlap = (index[cell] ?? []).first { previous in
                    // Adjacent points on the same ordinary street are not a revisit.
                    guard along - previous.along > 35 else { return false }
                    let dx = previous.edge.b.x - previous.edge.a.x
                    let dy = previous.edge.b.y - previous.edge.a.y
                    let denominator = hypot(dx, dy) * part
                    guard denominator > 0,
                          abs(dx * (edge.b.x - edge.a.x) + dy * (edge.b.y - edge.a.y)) / denominator > 0.9 else { return false }
                    return distance(middle, to: previous.edge) <= tolerance
                }
                if let overlap {
                    reused += part
                    // Only the short first/last access street may be shared.
                    // An internal waypoint spur is not a genuine circuit.
                    if overlap.along > accessAllowance || along < pathLength - accessAllowance {
                        interiorReuse += part
                        if run + part > longestInteriorRun {
                            longestInteriorRun = run + part
                            repairEdge = edge
                        }
                    }
                    run += (run > 0 ? gap : 0) + part
                    gap = 0
                    longest = max(longest, run)
                } else {
                    gap += part
                    if gap > 15 { run = 0; gap = 0 }
                }
                let sample = Sample(edge: edge, along: along)
                for x in Int(floor((min(edge.a.x, edge.b.x) - tolerance) / 20))...Int(floor((max(edge.a.x, edge.b.x) + tolerance) / 20)) {
                    for y in Int(floor((min(edge.a.y, edge.b.y) - tolerance) / 20))...Int(floor((max(edge.a.y, edge.b.y) + tolerance) / 20)) {
                        index[Cell(x: x, y: y), default: []].append(sample)
                    }
                }
                total += part
            }
        }
        var twiceArea = 0.0
        if let first = points.first, let last = points.last {
            for (a, b) in zip(points, points.dropFirst()) { twiceArea += a.x * b.y - b.x * a.y }
            twiceArea += last.x * first.y - first.x * last.y
        }
        return LoopQuality(total: total, reusedMeters: reused, longestReusedRun: longest, interiorReusedMeters: interiorReuse,
            area: abs(twiceArea) / 2,
            closure: points.first.flatMap { first in points.last.map { first.distance(to: $0) } } ?? .infinity,
            repairEdge: repairEdge)
    }

    static func similarity(_ a: Set<Cell>, _ b: Set<Cell>) -> Double {
        Double(a.intersection(b).count) / Double(max(1, min(a.count, b.count)))
    }

    static func waypoint(from origin: CLLocationCoordinate2D, meters: Double, bearing: Double) -> CLLocationCoordinate2D {
        let radius = 6_371_000.0, angle = meters / radius
        let lat = origin.latitude * .pi / 180, lon = origin.longitude * .pi / 180
        let newLat = asin(sin(lat) * cos(angle) + cos(lat) * sin(angle) * cos(bearing))
        let newLon = lon + atan2(sin(bearing) * sin(angle) * cos(lat), cos(angle) - sin(lat) * sin(newLat))
        return CLLocationCoordinate2D(latitude: newLat * 180 / .pi,
            longitude: (newLon * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180)
    }
}
