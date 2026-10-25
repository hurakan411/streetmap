import Foundation

enum CourseTravelMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case walking, cycling
    var id: String { rawValue }
    var symbol: String { self == .walking ? "figure.walk" : "bicycle" }
    // Used only to seed waypoint radii. Displayed ETA comes from MapKit.
    var seedMetersPerSecond: Double { self == .walking ? 1.15 : 3.9 }
    /// Indicative radius for a round trip, not a guaranteed reachable boundary.
    func directionRadius(minutes: Int) -> Double {
        Double(max(1, minutes)) * 60 * seedMetersPerSecond / 6
    }
    func title(japanese: Bool) -> String {
        self == .walking ? (japanese ? "徒歩" : "Walking") : (japanese ? "自転車" : "Cycling")
    }
}

/// Separate from WalkTrack: a proposed course must never become movement history.
struct RetainedWalkingCourse: Codable, Equatable {
    struct Coordinate: Codable, Equatable {
        let latitude: Double
        let longitude: Double
        var isValid: Bool {
            latitude.isFinite && longitude.isFinite
                && (-90...90).contains(latitude) && (-180...180).contains(longitude)
        }
    }
    struct Stop: Codable, Equatable {
        let id: String
        let name: String
        let coordinate: Coordinate
        let symbol: String
    }

    let version: Int
    let id: UUID
    let coordinates: [Coordinate]
    let distance: Double
    let seconds: Double
    let unwalkedDistance: Double
    let stops: [Stop]
    // Missing in existing saved proposals: restore those as walking courses.
    var travelMode: CourseTravelMode? = nil
    var advisories: [String]? = nil

    func validate() throws {
        guard version == 1, (2...50_000).contains(coordinates.count),
              coordinates.allSatisfy(\.isValid),
              distance.isFinite, distance > 0, seconds.isFinite, seconds > 0,
              unwalkedDistance.isFinite, (0...distance).contains(unwalkedDistance),
              stops.count <= 20, (advisories?.count ?? 0) <= 40,
              advisories?.allSatisfy({ $0.count <= 2048 }) ?? true,
              stops.allSatisfy({ $0.coordinate.isValid && $0.name.count <= 512
                  && $0.id.count <= 512 && $0.symbol.count <= 100 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}

struct RetainedWalkingCourseStorage {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Michi", isDirectory: true)
            .appendingPathComponent("retained-walking-course.json")
    }

    func load() throws -> RetainedWalkingCourse? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        let course = try JSONDecoder().decode(RetainedWalkingCourse.self, from: Data(contentsOf: url))
        try course.validate()
        return course
    }

    func save(_ course: RetainedWalkingCourse) throws {
        try course.validate()
        let data = try JSONEncoder().encode(course)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
