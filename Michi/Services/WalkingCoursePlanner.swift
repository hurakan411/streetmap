import Combine
import CoreLocation
import MapKit

struct WalkingCourseStop: Identifiable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let symbol: String
}

struct WalkingCourse: Identifiable {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
    let distance: Double
    let seconds: Double
    let unwalkedDistance: Double
    var stops: [WalkingCourseStop] = []
    let score: Double
    let footprint: Set<WalkingCourseGeometry.Cell>
    let travelMode: CourseTravelMode
    let advisories: [String]

    init(id: UUID = UUID(), coordinates: [CLLocationCoordinate2D], distance: Double,
         seconds: Double, unwalkedDistance: Double, stops: [WalkingCourseStop] = [],
         score: Double, footprint: Set<WalkingCourseGeometry.Cell>, travelMode: CourseTravelMode = .walking, advisories: [String] = []) {
        self.id = id; self.coordinates = coordinates; self.distance = distance
        self.seconds = seconds; self.unwalkedDistance = unwalkedDistance
        self.stops = stops; self.score = score; self.footprint = footprint
        self.travelMode = travelMode
        self.advisories = advisories
    }

    var retained: RetainedWalkingCourse {
        RetainedWalkingCourse(version: 1, id: id,
            coordinates: coordinates.map { .init(latitude: $0.latitude, longitude: $0.longitude) },
            distance: distance, seconds: seconds, unwalkedDistance: unwalkedDistance,
            stops: stops.map { .init(id: $0.id, name: $0.name,
                coordinate: .init(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude), symbol: $0.symbol) },
            travelMode: travelMode, advisories: advisories)
    }

    init(retained: RetainedWalkingCourse) {
        self.init(id: retained.id,
            coordinates: retained.coordinates.map { .init(latitude: $0.latitude, longitude: $0.longitude) },
            distance: retained.distance, seconds: retained.seconds, unwalkedDistance: retained.unwalkedDistance,
            stops: retained.stops.map { .init(id: $0.id, name: $0.name,
                coordinate: .init(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude), symbol: $0.symbol) },
            score: 0, footprint: [], travelMode: retained.travelMode ?? .walking, advisories: retained.advisories ?? [])
    }
}

@MainActor
final class WalkingCoursePlanner: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var origin: CLLocationCoordinate2D?
    @Published private(set) var originName = ""
    @Published private(set) var minutes = 30
    @Published private(set) var travelMode: CourseTravelMode = .walking
    @Published private(set) var direction = WalkingCourseGeometry.Direction()
    @Published private(set) var courses: [WalkingCourse] = []
    @Published var selection = 0
    @Published private(set) var isLoading = false
    @Published private(set) var progress = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var cameraRevision = 0
    @Published private(set) var retainedCourse: WalkingCourse?
    @Published var retentionError: String?
    private let retentionStorage: RetainedWalkingCourseStorage
    private var generation: Task<Void, Never>?
    private var requestID = UUID()
    private let engine = WalkingCourseEngine()
    var selectedCourse: WalkingCourse? { courses.indices.contains(selection) ? courses[selection] : nil }

    init(retentionStorage: RetainedWalkingCourseStorage = .init()) {
        self.retentionStorage = retentionStorage
        // A corrupt proposal must not interfere with loading real recording history.
        if let saved = try? retentionStorage.load() { retainedCourse = WalkingCourse(retained: saved) }
    }

    func retainSelectedCourse(japanese: Bool) -> Bool {
        guard let course = selectedCourse else { return false }
        do {
            try retentionStorage.save(course.retained)
            retainedCourse = course
            return true
        } catch {
            retentionError = japanese ? "コースを保存できませんでした。空き容量などを確認して、もう一度お試しください。"
                : "Could not save the course. Check available storage and try again."
            return false
        }
    }

    func clearRetainedCourse(japanese: Bool) {
        do {
            try retentionStorage.clear()
            retainedCourse = nil
        } catch {
            retentionError = japanese ? "コースの保存を解除できませんでした。もう一度お試しください。"
                : "Could not remove the saved course. Please try again."
        }
    }

    func focusRetainedCourse() { cameraRevision += 1 }

    func open(at coordinate: CLLocationCoordinate2D?, name: String) {
        isPresented = true
        if origin == nil { origin = coordinate; originName = name }
    }
    func close() {
        cancel()
        isPresented = false
    }
    private func cancel() {
        requestID = UUID()
        generation?.cancel(); generation = nil
        isLoading = false
    }
    func setOrigin(_ coordinate: CLLocationCoordinate2D, name: String) {
        cancel(); origin = coordinate; originName = name
        courses = []; selection = 0; errorMessage = nil; cameraRevision += 1
    }
    func setMinutes(_ value: Int) {
        guard value != minutes else { return }
        cancel(); minutes = value; courses = []; selection = 0; errorMessage = nil
    }
    func setTravelMode(_ mode: CourseTravelMode) {
        guard mode != travelMode else { return }
        cancel(); travelMode = mode; courses = []; selection = 0; errorMessage = nil
    }
    func setDirection(bearing: Double, opening: Double) {
        let next = WalkingCourseGeometry.Direction(bearing: bearing, opening: opening)
        guard next != direction else { return }
        cancel(); direction = next; courses = []; selection = 0; errorMessage = nil
    }
    func select(_ offset: Int) {
        guard !courses.isEmpty else { return }
        selection = (selection + offset + courses.count) % courses.count
        cameraRevision += 1
    }
    func generate(tracks: [WalkTrack], japanese: Bool) {
        cancel()
        guard let origin else {
            errorMessage = japanese ? "出発地を選んでください" : "Choose a starting point."
            return
        }
        guard direction.opening >= 8 else {
            courses = []
            errorMessage = japanese ? "周回を探すには、扇形を少し広げてください" : "Widen the sector a little to find a loop."
            return
        }
        let id = UUID(); requestID = id
        let duration = minutes
        let mode = travelMode
        let direction = self.direction
        courses = []; selection = 0; errorMessage = nil; progress = 0; isLoading = true
        let reportProgress: @Sendable (Int) -> Void = { [weak self] count in
            Task { @MainActor [weak self] in
                guard self?.requestID == id else { return }
                self?.progress = count
            }
        }
        generation = Task { [weak self, engine] in
            do {
                let results = try await engine.propose(from: origin, minutes: duration, direction: direction,
                    tracks: tracks, travelMode: mode, progress: reportProgress)
                try Task.checkCancellation()
                guard let self, requestID == id else { return }
                courses = results
                isLoading = false; cameraRevision += 1
                if results.isEmpty {
                    errorMessage = japanese ? "\(mode.title(japanese: true))の周回が見つかりません。時間・出発地・扇形の広さを変えてください。"
                        : "No loop with little backtracking found. Try another duration, start or a wider sector."
                }
            } catch is CancellationError {
                // A superseded request must not replace a newer result.
            } catch {
                guard let self, requestID == id else { return }
                isLoading = false
                errorMessage = mode == .cycling
                    ? (japanese ? "自転車コースを取得できませんでした。通信状況や、Appleマップが自転車経路に対応している地域か確認してください。"
                        : "Could not load cycling routes. Check your connection and Apple Maps cycling availability in this area.")
                    : (japanese ? "コースを取得できませんでした。通信状況を確認し、再試行してください。"
                        : "Could not load routes. Check your connection and try again.")
            }
        }
    }
}

/// Serial, bounded MapKit requests; CPU work stays off the UI actor. No proposed
/// polyline is persisted as a recorded track, and no raw history is sent to Apple.
actor WalkingCourseEngine {
    private var cache: [String: [MKRoute]] = [:]

    func propose(from origin: CLLocationCoordinate2D, minutes: Int, direction: WalkingCourseGeometry.Direction, tracks: [WalkTrack],
                 travelMode: CourseTravelMode = .walking,
                 diagnostic: (@Sendable (String) -> Void)? = nil,
                 progress: @escaping @Sendable (Int) -> Void) async throws -> [WalkingCourse] {
        let center = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let targetSeconds = Double(minutes * 60)
        let targetDistance = targetSeconds * travelMode.seedMetersPerSecond
        // Only reliable observations of the chosen mode across ALL dates, irrespective of
        // the map's current date or transport visibility filters.
        var edges: [(CLLocationCoordinate2D, CLLocationCoordinate2D)] = []
        for track in tracks {
            try Task.checkCancellation()
            for leg in RecordedDistanceCalculator.legs(from: track.rawPoints, isEstimatedTrack: track.isEstimated == true) {
                guard (travelMode == .walking ? leg.mode == .walking : leg.mode == .cycling),
                      leg.start.location.distance(from: center) < targetDistance + 500 else { continue }
                edges.append((leg.start.coordinate, leg.end.coordinate))
            }
        }
        let footprint = WalkingCourseGeometry.Footprint(coordinate: origin, walkingEdges: edges)
        var candidates: [WalkingCourse] = []
        func ranked(_ input: [WalkingCourse]) -> [WalkingCourse] {
            input.sorted {
                let a = WalkingCourseGeometry.durationIsPreferred($0.seconds, target: targetSeconds)
                let b = WalkingCourseGeometry.durationIsPreferred($1.seconds, target: targetSeconds)
                return a != b ? a : $0.score > $1.score
            }
        }
        // Eight compass seeds plus at most two corridor-repair trials. Every
        // repair is routed by Apple; no generated straight line is displayed.
        var scale = 1.0
        var seed = 0, attempt = 0, repairsCreated = 0
        var repairs: [(waypoints: [CLLocationCoordinate2D], retry: Int)] = []
        search: while attempt < WalkingCourseGeometry.maximumSearchTrials && (seed < 8 || !repairs.isEmpty) {
            try Task.checkCancellation()
            let waypoints: [CLLocationCoordinate2D]
            let retry: Int
            if !repairs.isEmpty {
                let repair = repairs.removeFirst()
                waypoints = repair.waypoints; retry = repair.retry
            } else {
                waypoints = WalkingCourseGeometry.directionalWaypoints(origin: origin, distance: targetDistance,
                    direction: direction, attempt: seed, scale: scale)
                seed += 1; retry = 0
            }
            attempt += 1
            let locations = [origin, waypoints[0], waypoints[1], origin]
            var coordinates: [CLLocationCoordinate2D] = []
            var meters = 0.0, seconds = 0.0
            var advisories: [String] = []
            var failed = false
            for index in 0..<3 {
                do {
                    let route = try await travelRoute(from: locations[index], to: locations[index + 1], avoiding: coordinates, mode: travelMode)
                    // MapKit can report .automobile even for an explicit
                    // cycling response (verified on iOS 26.5). The request and
                    // mode-separated cache establish the requested travel mode.
                    for notice in route.advisoryNotices where !advisories.contains(notice) { advisories.append(notice) }
                    let points = Self.coordinates(route.polyline)
                    guard points.count > 1 else { failed = true; break }
                    if let last = coordinates.last, Self.distance(last, points[0]) > 35 { failed = true; break }
                    coordinates.append(contentsOf: coordinates.isEmpty ? points : Array(points.dropFirst()))
                    meters += route.distance; seconds += route.expectedTravelTime
                } catch is CancellationError { throw CancellationError() }
                catch {
                    diagnostic?("attempt=\(attempt) routeError=\((error as NSError).domain):\((error as NSError).code)")
                    if let error = error as? MKError, error.code == .loadingThrottled || error.code == .serverFailure {
                        // A later service error must not discard valid results.
                        if !candidates.isEmpty { break search }
                        throw error
                    }
                    failed = true; break
                }
            }
            progress(attempt)
            diagnostic?("attempt=\(attempt) retry=\(retry) routed=\(!failed) meters=\(Int(meters)) seconds=\(Int(seconds))")
            guard !failed, let first = coordinates.first, let last = coordinates.last,
                  Self.distance(first, last) <= 35, Self.distance(first, origin) <= 80,
                  meters > 300, seconds > 0 else { continue }
            let original = WalkingCourseGeometry.metrics(coordinates, footprint: footprint)
            coordinates = WalkingCourseGeometry.removingWaypointSpurs(coordinates, footprint: footprint)
            let metrics = WalkingCourseGeometry.metrics(coordinates, footprint: footprint)
            // Distances and ETA must describe the cleaned path, not the removed
            // waypoint detour. MapKit's ETA is scaled by retained walking length.
            let retainedFraction = metrics.total / max(original.total, 1)
            meters *= retainedFraction; seconds *= retainedFraction
            let ratio = seconds / targetSeconds
            // Damping avoids alternating between too-long and too-short seeds.
            if retry == 0 { scale = min(1.6, max(0.55, scale / sqrt(max(0.1, ratio)))) }
            diagnostic?("attempt=\(attempt) durationRatio=\(ratio) scale=\(scale)")
            guard WalkingCourseGeometry.durationIsUsable(seconds, target: targetSeconds) else { continue }
            let loop = WalkingCourseGeometry.loopQuality(coordinates, footprint: footprint)
            let acceptable = loop.isAcceptable(forCycling: travelMode == .cycling)
            diagnostic?("attempt=\(attempt) loop=\(acceptable) reuse=\(loop.retracedFraction) run=\(loop.longestReusedRun) interior=\(loop.interiorReusedMeters) areaRatio=\(loop.normalizedArea)")
            guard acceptable else {
                if repairsCreated < 2, retry < 2,
                   let shifted = WalkingCourseGeometry.repairWaypoints(waypoints, quality: loop, footprint: footprint,
                        direction: direction, retry: retry) {
                    repairs.append((shifted, retry + 1)); repairsCreated += 1
                    diagnostic?("attempt=\(attempt) queuedCorridorRepair=true")
                }
                continue
            }
            let directionFit = WalkingCourseGeometry.directionFraction(coordinates, footprint: footprint, direction: direction)
            diagnostic?("attempt=\(attempt) direction=\(directionFit)")
            guard directionFit >= 0.6 else { continue }
            let novel = min(meters, meters * metrics.unwalked / max(metrics.total, 1))
            let score = 2 * novel / meters + directionFit - 2.5 * abs(log(ratio)) - loop.retracedFraction * 3
            candidates.append(WalkingCourse(coordinates: coordinates, distance: meters, seconds: seconds,
                unwalkedDistance: novel, score: score, footprint: metrics.cells, travelMode: travelMode, advisories: advisories))
            var distinct: [WalkingCourse] = []
            for candidate in ranked(candidates).filter({ WalkingCourseGeometry.durationIsPreferred($0.seconds, target: targetSeconds) }) {
                if !distinct.contains(where: { WalkingCourseGeometry.similarity($0.footprint, candidate.footprint) > 0.78 }) {
                    distinct.append(candidate)
                }
            }
            if distinct.count >= 3 { break }
        }
        var selected: [WalkingCourse] = []
        for candidate in ranked(candidates) {
            guard !selected.contains(where: { WalkingCourseGeometry.similarity($0.footprint, candidate.footprint) > 0.78 }) else { continue }
            selected.append(candidate)
            if selected.count == 3 { break }
        }
        // POIs are optional. A failed search must not discard usable routes.
        if !selected.isEmpty {
            progress(WalkingCourseGeometry.maximumSearchTrials + 1)
            let stops = await nearbyStops(origin: origin, radius: targetDistance / 2)
            try Task.checkCancellation()
            for index in selected.indices {
                let path = selected[index].coordinates.map(footprint.project)
                selected[index].stops = stops.filter { stop in
                    let p = footprint.project(stop.coordinate)
                    return zip(path, path.dropFirst()).contains {
                        WalkingCourseGeometry.distance(p, to: .init(a: $0.0, b: $0.1)) <= 90
                    }
                }.prefix(3).map { $0 }
            }
        }
        return selected
    }

    private func travelRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                             avoiding previous: [CLLocationCoordinate2D], mode: CourseTravelMode) async throws -> MKRoute {
        try Task.checkCancellation()
        let key = "\(mode.rawValue)|\(from.latitude),\(from.longitude)|\(to.latitude),\(to.longitude)"
        if let routes = cache[key] { return chooseRoute(routes, avoiding: previous) }
        try await Task.sleep(nanoseconds: 350_000_000)
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = mode == .walking ? .walking : .cycling
        request.requestsAlternateRoutes = true
        let directions = MKDirections(request: request)
        let timeout = Task { try await Task.sleep(nanoseconds: 18_000_000_000); directions.cancel() }
        defer { timeout.cancel() }
        let response = try await withTaskCancellationHandler {
            try await directions.calculate()
        } onCancel: { directions.cancel() }
        try Task.checkCancellation()
        guard !response.routes.isEmpty else {
            throw MKError(.directionsNotFound)
        }
        // Keep Apple's explicit cycling response, including mixed cycling /
        // pushing sections. Do not use the response's unreliable primary type
        // as the request provenance. Conservatively reject highway routes.
        let routes = mode == .cycling ? response.routes.filter { !$0.hasHighways } : response.routes
        guard !routes.isEmpty else { throw MKError(.directionsNotFound) }
        if cache.count >= 60 { cache.removeAll() }
        cache[key] = routes
        return chooseRoute(routes, avoiding: previous)
    }

    private func chooseRoute(_ routes: [MKRoute], avoiding previous: [CLLocationCoordinate2D]) -> MKRoute {
        let fastest = routes.map(\.expectedTravelTime).min() ?? 0
        guard let origin = previous.first, previous.count > 1 else {
            return routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime })!
        }
        let frame = WalkingCourseGeometry.Footprint(coordinate: origin, walkingEdges: [])
        let previousReuse = WalkingCourseGeometry.loopQuality(previous, footprint: frame).reusedMeters
        // MapKit may provide only one walking alternative. The final loop gate
        // still rejects a return along the same street instead of inventing a path.
        return routes.filter { $0.expectedTravelTime <= max(1, fastest) * 1.8 }.min { a, b in
            func cost(_ route: MKRoute) -> Double {
                let path = previous + Self.coordinates(route.polyline).dropFirst()
                let reused = max(0, WalkingCourseGeometry.loopQuality(path, footprint: frame).reusedMeters - previousReuse)
                return route.expectedTravelTime * (1 + 5 * reused / max(1, route.distance))
            }
            return cost(a) < cost(b)
        } ?? routes[0]
    }

    private func nearbyStops(origin: CLLocationCoordinate2D, radius: Double) async -> [WalkingCourseStop] {
        var result: [WalkingCourseStop] = []
        var names = Set<String>()
        for (query, symbol) in [("park", "tree.fill"), ("shrine", "building.columns"), ("bookstore", "books.vertical")] {
            guard !Task.isCancelled else { break }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = MKCoordinateRegion(center: origin, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
            request.resultTypes = .pointOfInterest
            if query == "park" { request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.park, .nationalPark]) }
            if query == "bookstore" { request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.store]) }
            let search = MKLocalSearch(request: request)
            let timeout = Task { try await Task.sleep(nanoseconds: 8_000_000_000); search.cancel() }
            let response = try? await withTaskCancellationHandler { try await search.start() } onCancel: { search.cancel() }
            timeout.cancel()
            for item in response?.mapItems ?? [] {
                guard let name = item.name,
                      item.pointOfInterestCategory != .parking,
                      Self.distance(origin, item.placemark.coordinate) <= radius + 200 else { continue }
                let lower = name.lowercased()
                // Natural-language search can return a nearby but unrelated
                // business. Categories alone cannot distinguish stores/shrines.
                if query == "shrine" && !["神社", "神宮", "稲荷", "天満宮", "shrine", "jinja", "jingu"].contains(where: lower.contains) { continue }
                if query == "bookstore" && !["書店", "書房", "本屋", "紀伊國屋", "ジュンク堂", "丸善", "book", "tsutaya"].contains(where: lower.contains) { continue }
                if query == "park" && item.pointOfInterestCategory != .park && item.pointOfInterestCategory != .nationalPark { continue }
                guard names.insert(name).inserted else { continue }
                result.append(.init(id: "\(name)|\(item.placemark.coordinate.latitude)", name: name,
                    coordinate: item.placemark.coordinate, symbol: symbol))
            }
        }
        return result
    }

    static func coordinates(_ line: MKPolyline) -> [CLLocationCoordinate2D] {
        let points = line.points()
        return (0..<line.pointCount).map { points[$0].coordinate }
    }
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
