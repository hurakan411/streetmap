import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
var distribution = MapTimingDistribution()
for _ in 0..<95 { distribution.add(16) }
for _ in 0..<5 { distribution.add(100) }
distribution.add(.nan); distribution.add(-1)
check(distribution.count == 100 && distribution.p95MS == 16, "p95/count")
check(abs(distribution.averageMS - 20.2) < 0.0001 && distribution.maximumMS == 100, "mean/max")

let recorder = MapPerformanceRecorder()
check(recorder.begin("inactive", at: 0) == nil, "Collection enabled without explicit session")
recorder.start(stage: "mapOnly", metadata: ["theme": "editorial"], at: 10)
let old = recorder.begin("stale", at: 10)!
let token = recorder.begin("main.example", at: 10.001)!
recorder.end(token, at: 10.021)
recorder.frame(interval: 0.016, expected: 1.0 / 60)
recorder.frame(interval: 0.050, expected: 1.0 / 60)
let result = recorder.stop(at: 11)!
check(result.operations["main.example"]!.count == 1, "Operation missing")
check(abs(result.operations["main.example"]!.maximumMS - 20) < 0.0001, "Operation timing")
check(result.interactionFrames.count == 2 && result.hitchIntervals == 1 && result.estimatedMissedCallbacks == 2, "Hitch classification")
check(result.durationSeconds == 1 && !result.interrupted, "Session duration")
check(recorder.stop() == nil, "Duplicate stop emitted data")
recorder.start(stage: "sampling")
let sampled = (0..<32).compactMap { _ in recorder.beginSampled("sample", every: 16) }
check(sampled.count == 2, "Draw sampling frequency changed")
for token in sampled { recorder.end(token) }
check(recorder.stop()!.operations["sample"]!.count == 2, "Sampled draws missing")

recorder.start(stage: "routes", at: 20)
recorder.end(old, at: 20.01)
DispatchQueue.concurrentPerform(iterations: 2_000) { _ in
    let token = recorder.begin("render.concurrent", at: 20.1)
    recorder.end(token, at: 20.102)
}
let concurrent = recorder.stop(interrupted: true, at: 21)!
check(concurrent.operations["stale"] == nil, "Old worker contaminated new session")
check(concurrent.operations["render.concurrent"]!.count == 2_000, "Concurrent samples lost")
check(concurrent.interrupted && concurrent.interactionFrames.count == 0, "Empty sessions must stay empty")
let data = try JSONEncoder().encode(concurrent)
let copy = try JSONDecoder().decode(MapPerformanceRecorder.Result.self, from: data)
check(copy.operations["render.concurrent"]!.count == 2_000, "Report serialization")
check(MapPerformanceProbe.begin("normal.build") == nil, "Normal builds must have inactive hooks")
print("PASS: timing aggregates, p95, hitches, opt-in collection, concurrent workers, stale-session rejection, interrupted/empty sessions, report serialization, ordinary-build no-op hooks")
