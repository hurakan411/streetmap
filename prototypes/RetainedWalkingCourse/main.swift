import Foundation

var assertions = 0
func check(_ value: Bool, _ message: String) {
    assertions += 1
    if !value { print("FAIL: \(message)"); exit(1) }
}
func rejects(_ message: String, _ action: () throws -> Void) {
    do { try action(); check(false, message) } catch { check(true, message) }
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StreetPrintRetainedTests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let history = directory.appendingPathComponent("walk-history.json")
let sentinel = Data("untouched recording history".utf8)
try sentinel.write(to: history)
let url = directory.appendingPathComponent("retained-walking-course.json")
let storage = RetainedWalkingCourseStorage(url: url)

func course(id: UUID = UUID(), version: Int = 1, latitude: Double = 35.6896,
            distance: Double = 1800, seconds: Double = 1800, unwalked: Double = 1200) -> RetainedWalkingCourse {
    .init(version: version, id: id, coordinates: [
        .init(latitude: latitude, longitude: 139.7006),
        .init(latitude: 35.69, longitude: 139.71),
        .init(latitude: latitude, longitude: 139.7006)
    ], distance: distance, seconds: seconds, unwalkedDistance: unwalked,
        stops: [.init(id: "park", name: "公園", coordinate: .init(latitude: 35.69, longitude: 139.71), symbol: "tree.fill")])
}

check(try storage.load() == nil, "no saved course initially")
let original = course()
try storage.save(original)
check(try storage.load() == original, "round-trip all coordinates, metrics, stops and identity")
let reopened = RetainedWalkingCourseStorage(url: url)
check(try reopened.load() == original, "restore in a new storage instance without any expiry")
let legacyData = try JSONEncoder().encode(original)
check(try JSONDecoder().decode(RetainedWalkingCourse.self, from: legacyData).travelMode == nil,
    "Legacy saved courses without a travel mode remain readable")
var cyclingCourse = original
cyclingCourse.travelMode = .cycling
cyclingCourse.advisories = ["共有道路と幹線道路", "一部で押し歩き"]
try storage.save(cyclingCourse)
check(try reopened.load()?.travelMode == .cycling, "Cycling mode survives saving and reopening")
check(try reopened.load()?.advisories == cyclingCourse.advisories, "Apple cycling notices survive saving and reopening")
try storage.save(original)
check(CourseTravelMode.allCases.count == 2 && CourseTravelMode.cycling.seedMetersPerSecond > CourseTravelMode.walking.seedMetersPerSecond,
    "Exactly walking/cycling choices with distinct seed speeds")
check(abs(CourseTravelMode.walking.directionRadius(minutes: 30) - 345) < 0.01,
    "30-minute walking circle has a 345m geographic radius")
check(abs(CourseTravelMode.cycling.directionRadius(minutes: 30) - 1170) < 0.01,
    "30-minute cycling circle has a 1170m geographic radius")
check(CourseTravelMode.cycling.directionRadius(minutes: 30) / CourseTravelMode.walking.directionRadius(minutes: 30) > 3.3,
    "Cycling circle grows with speed instead of sharing a fixed pixel radius")
check(CourseTravelMode.cycling.directionRadius(minutes: 60) == CourseTravelMode.cycling.directionRadius(minutes: 30) * 2,
    "Doubling duration doubles the geographic radius")

for invalid in [course(version: 2), course(latitude: 91), course(distance: -.infinity),
                course(seconds: 0), course(unwalked: -1), course(unwalked: 2000)] {
    rejects("invalid proposal rejected") { try storage.save(invalid) }
    check(try storage.load() == original, "invalid replacement preserves saved proposal")
}

let replacement = course()
try storage.save(replacement)
check(try reopened.load() == replacement, "one saved route, atomically replaced")
check(try Data(contentsOf: history) == sentinel, "saving/replacing never touches real history")
try storage.clear()
check(try reopened.load() == nil, "manual removal persists after reopening")
try storage.clear()
check(try Data(contentsOf: history) == sentinel, "removing never touches real history")

try Data("not JSON".utf8).write(to: url)
rejects("corrupt file rejected") { _ = try storage.load() }
try storage.save(original)
check(try storage.load() == original, "new selection can replace a corrupt saved proposal")
try storage.clear()
try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
rejects("write failure is propagated") { try storage.save(original) }
check(try Data(contentsOf: history) == sentinel, "even errors leave history untouched")
print("PASS: \(assertions) retained-course assertions (restore, replace, remove, validation, errors, history isolation)")
