import MapKit

/// Immutable transition geometry. Preparing/filtering/sorting this plan never
/// needs the UI thread. A frame is a plan reference and one progress index.
final class RouteRenderPlan {
    struct Style: Hashable {
        let frequency: Int
        let estimated: Bool
        var opacity: Double {
            let value = min(1, 0.48 + log2(Double(frequency) + 1) * 0.19)
            return estimated ? min(value, 0.58) : value
        }
        var width: CGFloat { 1.25 + min(5.2, CGFloat(log2(Double(frequency) + 1)) * 1.35) }
    }
    struct Entry {
        let segment: WeightedSegment
        let start: MKMapPoint
        let end: MKMapPoint
        let bounds: MKMapRect
        let style: Style
        let geometryVersion: Int
        let appearsAt: Int
        let disappearsAt: Int

        init(_ segment: WeightedSegment, appearsAt: Int, disappearsAt: Int) {
            self.segment = segment
            start = MKMapPoint(segment.start); end = MKMapPoint(segment.end)
            bounds = MKMapRect(x: min(start.x, end.x), y: min(start.y, end.y),
                width: max(0.001, abs(start.x - end.x)), height: max(0.001, abs(start.y - end.y)))
            style = Style(frequency: segment.frequency, estimated: segment.isEstimated)
            var hasher = Hasher()
            hasher.combine(segment.start.latitude); hasher.combine(segment.start.longitude)
            hasher.combine(segment.end.latitude); hasher.combine(segment.end.longitude)
            geometryVersion = hasher.finalize()
            self.appearsAt = appearsAt; self.disappearsAt = disappearsAt
        }
        func isVisible(at step: Int) -> Bool { appearsAt <= step && step < disappearsAt }
    }
    private indirect enum Node {
        case leaf(MKMapRect, [Int])
        case branch(MKMapRect, Node, Node)
        var bounds: MKMapRect {
            switch self { case .leaf(let r, _), .branch(let r, _, _): return r }
        }
        func collect(_ rect: MKMapRect, into result: inout [Int]) {
            guard bounds.intersects(rect) else { return }
            switch self {
            case .leaf(_, let ids): result.append(contentsOf: ids)
            case .branch(_, let a, let b): a.collect(rect, into: &result); b.collect(rect, into: &result)
            }
        }
    }
    let entries: [Entry]
    let events: [Int]
    let styles: Set<Style>
    let bounds: MKMapRect
    private let root: Node?
    var stepCount: Int { events.count }

    init?(previous: [WeightedSegment], target: [WeightedSegment]) {
        func before(_ a: WeightedSegment, _ b: WeightedSegment) -> Bool {
            a.firstVisitedAt == b.firstVisitedAt ? a.id < b.id : a.firstVisitedAt < b.firstVisitedAt
        }
        func same(_ a: WeightedSegment, _ b: WeightedSegment) -> Bool {
            a.start.latitude == b.start.latitude && a.start.longitude == b.start.longitude &&
            a.end.latitude == b.end.latitude && a.end.longitude == b.end.longitude &&
            a.frequency == b.frequency && a.isEstimated == b.isEstimated && a.transportMode == b.transportMode
        }
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let next = Dictionary(target.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let removals = old.values.filter { segment in next[segment.id].map { !same(segment, $0) } ?? true }
        let removed = removals.sorted { before($1, $0) }
        let added = next.values.filter { segment in old[segment.id].map { !same(segment, $0) } ?? true }
            .sorted(by: before)
        guard !Task.isCancelled else { return nil }
        let removalSteps = Dictionary(uniqueKeysWithValues: removed.enumerated().map { ($0.element.id, $0.offset + 1) })
        var list = previous.map { Entry($0, appearsAt: 0, disappearsAt: removalSteps[$0.id] ?? Int.max) }
        var eventIndices = Array(repeating: 0, count: removed.count)
        for (index, entry) in list.enumerated() {
            if let step = removalSteps[entry.segment.id] { eventIndices[step - 1] = index }
        }
        for (offset, segment) in added.enumerated() {
            eventIndices.append(list.count)
            list.append(Entry(segment, appearsAt: removed.count + offset + 1, disappearsAt: Int.max))
        }
        entries = list; events = eventIndices; styles = Set(list.map(\.style))
        bounds = list.reduce(MKMapRect.null) { $0.union($1.bounds) }
        func build(_ ids: [Int]) -> Node? {
            guard !ids.isEmpty, !Task.isCancelled else { return nil }
            let bounds = ids.reduce(MKMapRect.null) { $0.union(list[$1].bounds) }
            guard ids.count > 24 else { return .leaf(bounds, ids) }
            let horizontal = bounds.width >= bounds.height
            let sorted = ids.sorted {
                horizontal ? list[$0].bounds.midX < list[$1].bounds.midX : list[$0].bounds.midY < list[$1].bounds.midY
            }
            let middle = sorted.count / 2
            guard let a = build(Array(sorted[..<middle])), let b = build(Array(sorted[middle...])) else { return nil }
            return .branch(bounds, a, b)
        }
        root = build(Array(list.indices))
        if Task.isCancelled { return nil }
    }

    func visibleIndices(in rect: MKMapRect, step: Int) -> [Int] {
        var ids: [Int] = []
        root?.collect(rect, into: &ids)
        return ids.filter { entries[$0].isVisible(at: step) && entries[$0].bounds.intersects(rect) }.sorted()
    }
    func visibleSegments(at step: Int) -> [WeightedSegment] {
        entries.lazy.filter { $0.isVisible(at: step) }.map(\.segment)
    }
    func changedBounds(from first: Int, to last: Int) -> MKMapRect {
        guard last > first else { return .null }
        return events[first..<last].reduce(MKMapRect.null) { $0.union(entries[$1].bounds) }
    }
}

/// Immutable-frame storage shared by transition preparation and viewport export.
final class RouteAnimationState {
    struct Frame {
        let plan: RouteRenderPlan
        let step: Int
        let palette: RouteDrawingPalette?
    }
    private let lock = NSLock()
    private var frame: Frame?
    func snapshot() -> Frame? { lock.lock(); defer { lock.unlock() }; return frame }
    func install(_ plan: RouteRenderPlan, step: Int = 0, palette: RouteDrawingPalette? = nil) {
        lock.lock(); frame = Frame(plan: plan, step: step, palette: palette); lock.unlock()
    }
    func advance(to step: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let current = frame else { return }
        frame = Frame(plan: current.plan, step: min(current.plan.stepCount, max(current.step, step)), palette: current.palette)
    }
    func clear() { lock.lock(); frame = nil; lock.unlock() }
}

/// Immutable Core Graphics style, in screen points. No MKPolylineRenderer is
/// used to infer stroke properties, so MapKit cannot amplify width at far zoom.
final class RouteDrawingPalette {
    struct Stroke {
        let color: CGColor
        let screenWidth: CGFloat
        func mapWidth(at zoomScale: MKZoomScale) -> CGFloat? {
            guard zoomScale.isFinite, zoomScale > 0 else { return nil }
            let value = screenWidth / zoomScale
            return value.isFinite ? value : nil
        }
    }
    let strokes: [RouteRenderPlan.Style: Stroke]
    let maximumScreenWidth: CGFloat
    init(styles: Set<RouteRenderPlan.Style>, color: CGColor, lineScale: CGFloat) {
        strokes = Dictionary(uniqueKeysWithValues: styles.map { style in
            (style, Stroke(color: color.copy(alpha: style.opacity) ?? color, screenWidth: style.width * lineScale))
        })
        maximumScreenWidth = (strokes.values.map(\.screenWidth).max() ?? 0)
    }
}

/// One geographic surface stays registered across every pan/zoom and filter
/// animation. Only expanding history beyond a generous fixed envelope needs
/// a replacement; it is never a camera-dependent add/remove operation.
final class PersistentRouteOverlay: NSObject, MKOverlay {
    let state: RouteAnimationState
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D
    init(state: RouteAnimationState, contentBounds: MKMapRect) {
        self.state = state
        boundingMapRect = Self.envelope(for: contentBounds)
        coordinate = MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
        super.init()
    }
    static func envelope(for bounds: MKMapRect) -> MKMapRect {
        guard !bounds.isNull, !bounds.isEmpty else { return .world }
        // Includes screen-point caps even at world scale, and avoids changing
        // the registered surface for routine recording updates within a city.
        return bounds.insetBy(dx: -16_777_216, dy: -16_777_216).intersection(.world)
    }
}

final class PersistentRouteRenderer: MKOverlayRenderer {
    private let state: RouteAnimationState
    init(surface: PersistentRouteOverlay) {
        state = surface.state
        super.init(overlay: surface)
    }
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        #if STREETPRINT_DIAGNOSTICS
        let timing = MapPerformanceProbe.begin("render.persistentRoutes")
        defer { MapPerformanceProbe.end(timing) }
        #endif
        guard zoomScale.isFinite, zoomScale > 0, let frame = state.snapshot(),
              let palette = frame.palette else { return }
        let padding = Double(palette.maximumScreenWidth + 2) / zoomScale
        let indices = frame.plan.visibleIndices(in: mapRect.insetBy(dx: -padding, dy: -padding), step: frame.step)
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: rect(for: mapRect))
        context.setLineCap(.round); context.setLineJoin(.round)
        var lastStyle: RouteRenderPlan.Style?
        for index in indices {
            let entry = frame.plan.entries[index]
            if lastStyle != entry.style {
                guard let stroke = palette.strokes[entry.style], let width = stroke.mapWidth(at: zoomScale) else { continue }
                context.setStrokeColor(stroke.color); context.setLineWidth(width)
                lastStyle = entry.style
            }
            // Separate strokes preserve translucent round-cap overlaps; no
            // joining endpoints, opacity grouping, sampling or geometry edits.
            context.beginPath()
            context.move(to: point(for: entry.start))
            context.addLine(to: point(for: entry.end))
            context.strokePath()
        }
    }
}

