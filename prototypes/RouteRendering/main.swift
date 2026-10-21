import Foundation
import MapKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
typealias UIColor = NSColor
#endif

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
func edge(_ id: String, date: Double, frequency: Int = 1, shift: Double = 0) -> WeightedSegment {
    WeightedSegment(id: id, start: .init(latitude: 35.7 + shift, longitude: 139.7),
        end: .init(latitude: 35.701 + shift, longitude: 139.701), frequency: frequency,
        isEstimated: false, firstVisitedAt: Date(timeIntervalSince1970: date), transportMode: .walking)
}
let a = edge("A", date: 1), b = edge("B", date: 2), c = edge("C", date: 3)
let updatedB = edge("B", date: 2, frequency: 4)
let d = edge("D", date: 0), e = edge("E", date: 4)
let plan = RouteRenderPlan(previous: [a,b,c], target: [a,updatedB,d,e])!
let expected: [Set<String>] = [
    ["A","B","C"], ["A","B"], ["A"], ["A","D"], ["A","D","B"], ["A","D","B","E"]
]
check(plan.stepCount == 5, "Unchanged A must not be removed or redrawn")
for step in expected.indices {
    let visible = plan.visibleSegments(at: step)
    check(Set(visible.map(\.id)) == expected[step], "Chronological additions / reverse removals changed")
    if let value = visible.first(where: { $0.id == "B" }) {
        check(value.frequency == (step < 2 ? 1 : 4), "Stale frequency survived")
    }
}
let interrupted = plan.visibleSegments(at: 3)
let resumed = RouteRenderPlan(previous: interrupted, target: [a,b,c])!
check(Set(resumed.visibleSegments(at: 0).map(\.id)) == ["A","D"], "Interrupted state jumped")
check(Set(resumed.visibleSegments(at: resumed.stepCount).map(\.id)) == ["A","B","C"], "Rapid toggle lost edges")
let moved = RouteRenderPlan(previous: [a], target: [edge("A", date: 1, shift: 0.001)])!
check(moved.stepCount == 2 && moved.visibleSegments(at: 1).isEmpty, "Geometry changes must replace old line")
let unchanged = RouteRenderPlan(previous: [a,b,c], target: [c,b,a])!
check(unchanged.stepCount == 0, "Unchanged geometry must not be rebuilt")
let outside = MKMapRect(x: 0, y: 0, width: 100, height: 100)
check(plan.visibleIndices(in: outside, step: plan.stepCount).isEmpty, "Offscreen edges leak into viewport export")
let state = RouteAnimationState()
state.install(plan)
for step in 0...plan.stepCount { state.advance(to: step); check(state.snapshot()!.step == step, "Frame state lost") }
print("PASS: exact add/remove order, frequency and geometry replacement, interrupted transitions, no-op reuse, offscreen culling")

let palette = RouteDrawingPalette(styles: plan.styles,
    color: CGColor(red: 0, green: 0.3, blue: 1, alpha: 1), lineScale: 1.1)
state.install(plan, palette: palette)
let surface = PersistentRouteOverlay(state: state, contentBounds: plan.bounds)
for scale in [0.000001, 0.0005, 0.003, 0.02, 0.5] {
    for style in plan.styles {
        let stroke = palette.strokes[style]!
        check(abs(stroke.mapWidth(at: scale)! * scale - style.width * 1.1) < 0.000001,
            "Stroke grew/shrank in screen points during zoom")
    }
    // A camera change has no registration policy and never replaces surface.
    check(surface.boundingMapRect.contains(plan.bounds), "Persistent envelope lost routes")
}
check(palette.strokes.values.first!.mapWidth(at: .nan) == nil, "Invalid zoom accepted")
check(palette.strokes.values.first!.mapWidth(at: 0) == nil, "Zero zoom accepted")
for step in 0...plan.stepCount {
    state.advance(to: step)
    check(state.snapshot()!.palette === palette, "Animation detached palette")
    check(Set(state.snapshot()!.plan.visibleSegments(at: step).map(\.id)) == expected[step],
        "Persistent rendering changed temporal membership")
}
print("PASS: constant screen-point widths at five zooms, persistent geographic envelope, palette lifetime, exact temporal membership")

// Rasterize the actual production renderer at 1x/2x/3x display scales.
for scale in [0.000001, 0.0005, 0.003, 0.02, 0.5] {
    for pixelsPerPoint in [1, 2, 3] {
        let center = MKMapPoint(CLLocationCoordinate2D(latitude: 0, longitude: 0))
        let start = MKMapPoint(x: center.x - 50 / scale, y: center.y)
        let end = MKMapPoint(x: center.x + 50 / scale, y: center.y)
        let line = WeightedSegment(id: "raster", start: start.coordinate, end: end.coordinate,
            frequency: 1, isEstimated: false, firstVisitedAt: Date(), transportMode: .walking)
        let p = RouteRenderPlan(previous: [], target: [line])!
        let colors = RouteDrawingPalette(styles: p.styles, color: CGColor(red: 0, green: 0.3, blue: 1, alpha: 1), lineScale: 1.1)
        let animation = RouteAnimationState()
        animation.install(p, step: p.stepCount, palette: colors)
        let overlay = PersistentRouteOverlay(state: animation, contentBounds: p.bounds)
        let renderer = PersistentRouteRenderer(surface: overlay)
        let viewport = MKMapRect(x: center.x - 128 / scale, y: center.y - 128 / scale,
            width: 256 / scale, height: 256 / scale)
        let side = 256 * pixelsPerPoint
        func raster() -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: side * side * 4)
            bytes.withUnsafeMutableBytes { memory in
                let ctx = CGContext(data: memory.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                let local = renderer.rect(for: viewport)
                ctx.scaleBy(x: scale * Double(pixelsPerPoint), y: scale * Double(pixelsPerPoint))
                ctx.translateBy(x: -local.minX, y: -local.minY)
                renderer.draw(viewport, zoomScale: scale, in: ctx)
                ctx.flush()
            }
            return bytes
        }
        let bytes = raster()
        let centerX = side / 2
        let occupiedRows = (0..<side).filter { bytes[($0 * side + centerX) * 4 + 3] > 20 }
        let expectedPixels = colors.strokes.values.first!.screenWidth * CGFloat(pixelsPerPoint)
        check(abs(CGFloat(occupiedRows.count) - expectedPixels) <= 2,
            "Actual raster width wrong: zoom=\(scale), display=\(pixelsPerPoint), rows=\(occupiedRows.count)")
        check(occupiedRows.allSatisfy { abs($0 - side / 2) <= Int(ceil(expectedPixels)) },
            "Raster moved away from geographic center")
        let removal = RouteRenderPlan(previous: [line], target: [])!
        animation.install(removal, step: removal.stepCount, palette: colors)
        check(raster().allSatisfy { $0 == 0 }, "Removed route still rasterizes")
    }
}
print("PASS: production raster width/position and empty removal at five zooms × three display scales")

if CommandLine.arguments.count > 1 {
    struct Archive: Decodable { let tracks: [WalkTrack] }
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(Archive.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    let all = RouteSegmentBuilder.build(tracks: archive.tracks, range: Date.distantPast...Date.distantFuture)
    let begin = ProcessInfo.processInfo.systemUptime
    let initial = RouteRenderPlan(previous: [], target: all)!
    let prepareMs = (ProcessInfo.processInfo.systemUptime - begin) * 1000
    state.install(initial)
    var maximumFrameMs = 0.0
    for tick in 1...50 {
        let t = ProcessInfo.processInfo.systemUptime
        state.advance(to: Int(ceil(Double(initial.stepCount) * Double(tick) / 50)))
        maximumFrameMs = max(maximumFrameMs, (ProcessInfo.processInfo.systemUptime-t)*1000)
    }
    let persistent = PersistentRouteOverlay(state: state, contentBounds: initial.bounds)
    for _ in 0..<2 {
        var previous: [WeightedSegment] = []
        for mask in [7,1,2,4,0,3,5,6,7] {
            let modes = Set(TransportMode.allCases.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil })
            let target = all.filter { modes.contains($0.transportMode) }
            let transition = RouteRenderPlan(previous: previous, target: target)!
            check(persistent.boundingMapRect.contains(transition.bounds) || transition.bounds.isNull,
                "Filter required a new geographic surface")
            state.install(transition, step: transition.stepCount)
            let actual = transition.visibleSegments(at: transition.stepCount)
            let expected = Dictionary(uniqueKeysWithValues: target.map { ($0.id, $0) })
            check(Set(actual.map(\.id)) == Set(target.map(\.id)), "Mode filter lost history")
            for value in actual {
                check(expected[value.id].map { $0.frequency == value.frequency &&
                    $0.start.latitude == value.start.latitude && $0.end.longitude == value.end.longitude } ?? false,
                    "Filtered geometry or frequency changed")
            }
            previous = target
        }
    }
    print("Host-only: \(all.count) edges; background preparation \(prepareMs) ms; max frame bookkeeping \(maximumFrameMs) ms; one persistent surface across all filter combinations; not iPhone FPS")
}
