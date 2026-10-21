import CoreGraphics
import Foundation
import MapKit
import QuartzCore

/// A geographic lattice. Hexes move and scale naturally with the map and
/// never change their underlying geographic size or rebuild into screen slots.
struct MidnightHexGrid {
    struct ID: Hashable {
        let q: Int
        let r: Int
        let level: Int
    }

    let radius = 1024.0

    func center(of id: ID) -> CGPoint {
        CGPoint(x: 1.5 * radius * Double(id.q),
            y: sqrt(3) * radius * (Double(id.r) + Double(id.q) / 2))
    }

    func cell(at point: CGPoint) -> ID {
        let q = point.x / (1.5 * radius)
        let r = point.y / (sqrt(3) * radius) - q / 2
        var x = round(q), z = round(r)
        let y = round(-q - r)
        let dx = abs(x - q), dz = abs(z - r), dy = abs(y + q + r)
        if dx > dy && dx > dz { x = -y - z }
        else if dz > dy { z = -x - y }
        return ID(q: Int(x), r: Int(z), level: 10)
    }

    func cells(in rect: CGRect) -> [ID] {
        guard !rect.isNull, !rect.isEmpty, rect.width.isFinite, rect.height.isFinite else { return [] }
        let minQ = Int(floor(rect.minX / (1.5 * radius))) - 1
        let maxQ = Int(ceil(rect.maxX / (1.5 * radius))) + 1
        var result: [ID] = []
        for q in minQ...maxQ {
            let minR = Int(floor(rect.minY / (sqrt(3) * radius) - Double(q) / 2)) - 1
            let maxR = Int(ceil(rect.maxY / (sqrt(3) * radius) - Double(q) / 2)) + 1
            for r in minR...maxR { result.append(ID(q: q, r: r, level: 10)) }
        }
        return result
    }

    static func seed(_ id: ID) -> UInt64 {
        var n = UInt64(bitPattern: Int64(id.q)) &* 0x9E3779B185EBCA87
        n ^= UInt64(bitPattern: Int64(id.r)) &* 0xC2B2AE3D27D4EB4F
        n ^= n >> 30
        n &*= 0xBF58476D1CE4E5B9
        return n ^ (n >> 27)
    }
}

/// Geographic cells project into a lightweight Core Animation canvas.
/// Only the cells visible at mode entry are queued; routine updates preserve
/// that queue and never erase an in-flight placement animation.
final class MidnightHexSurface {
    struct Tile {
        let id: MidnightHexGrid.ID
        let center: CGPoint
        let radius: Double
        let coverage: Double
        let fallProgress: Double?
    }

    private var index: PaperSegmentIndex
    var segmentIndex: PaperSegmentIndex { index }
    private var covered: [MidnightHexGrid.ID] = []
    private var hasCapturedEntry = false
    private var onChange: (() -> Void)?
    private var valid = true
    private var cachedBounds = CGRect.null
    private var cachedWidth = 0.0
    private var revealedCells: [MidnightHexGrid.ID: Bool] = [:]
    private(set) var geometryRevision = 0
    private(set) var renderBounds = CGRect.null
    private(set) var mapOrigin = MKMapPoint(x: 0, y: 0)
    private(set) var entryStartedAt: TimeInterval = 0
    private(set) var entryDelays: [MidnightHexGrid.ID: Double] = [:]
    private(set) var needsProjection = true
    private(set) var isOverview = false
    private(set) var overviewSegments: [TornPaperRenderer.Segment] = []
    static let transitionDuration: TimeInterval = 2
    static let fallDuration: TimeInterval = 0.65
    static let localRadius = 24.0
    static var mapUnitsPerLocalPoint: Double { MidnightHexGrid().radius / localRadius }

    init(segments: [TornPaperRenderer.Segment], preparedIndex: PaperSegmentIndex? = nil) {
        index = preparedIndex ?? PaperSegmentIndex(segments: segments)
    }
    func setCallback(_ callback: (() -> Void)?) { onChange = callback }

    func update(segments: [TornPaperRenderer.Segment], preparedIndex: PaperSegmentIndex? = nil) {
        index = preparedIndex ?? PaperSegmentIndex(segments: segments)
        revealedCells.removeAll(keepingCapacity: true)
        needsProjection = true
        if valid { onChange?() }
    }

    func localPoint(_ point: MKMapPoint) -> CGPoint {
        CGPoint(x: (point.x - mapOrigin.x) / Self.mapUnitsPerLocalPoint,
            y: (point.y - mapOrigin.y) / Self.mapUnitsPerLocalPoint)
    }

    @discardableResult
    func updateViewport(_ bounds: CGRect,
                        time: TimeInterval = ProcessInfo.processInfo.systemUptime,
                        unproject: (CGPoint) -> MKMapPoint,
                        project: (MKMapPoint) -> CGPoint) -> Bool {
        guard valid, !bounds.isEmpty else { return false }
        let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY)].map(unproject)
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        let mapBounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let grid = MidnightHexGrid()
        if !hasCapturedEntry {
            let center = grid.center(of: grid.cell(at: CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)))
            mapOrigin = MKMapPoint(x: center.x, y: center.y)
        }
        let columns = ceil(mapBounds.width / (grid.radius * 1.5)) + 4
        let rows = ceil(mapBounds.height / (grid.radius * sqrt(3))) + 4
        // Hysteresis avoids churning between raster and individual pieces
        // while a pinch hovers around the detail threshold.
        let overviewRequested = columns * rows > (isOverview ? 700 : 900)
        let ratio = mapBounds.width / max(1, cachedWidth)
        if !needsProjection, overviewRequested == isOverview,
           cachedBounds.contains(mapBounds), !isOverview || (0.65...1.5).contains(ratio) {
            return false
        }
        isOverview = overviewRequested
        // The existing geographic canvas follows every camera frame. Only
        // crossing this overscan margin requires new coverage/layer work.
        cachedBounds = mapBounds.insetBy(dx: -mapBounds.width * 0.18, dy: -mapBounds.height * 0.18)
        cachedWidth = mapBounds.width
        renderBounds = cachedBounds
        overviewSegments = []
        covered = []
        if isOverview {
            let rect = MKMapRect(x: cachedBounds.minX, y: cachedBounds.minY,
                width: cachedBounds.width, height: cachedBounds.height)
            overviewSegments = index.segments(intersecting: rect)
        } else {
            if revealedCells.count > 12_000 { revealedCells.removeAll(keepingCapacity: true) }
            covered = grid.cells(in: cachedBounds).filter { id in
                if let revealed = revealedCells[id] { return !revealed }
                let c = grid.center(of: id), world = MKMapPoint(x: c.x, y: c.y)
                let revealed = isRevealed(world)
                revealedCells[id] = revealed
                return !revealed
            }
        }
        needsProjection = false
        geometryRevision += 1
        if !hasCapturedEntry {
            hasCapturedEntry = true
            entryStartedAt = time
            // Project three points once, not thousands of MapKit conversions
            // inside a sort. Capture only the entry viewport, not overscan.
            let p = project(mapOrigin)
            let x = project(MKMapPoint(x: mapOrigin.x + grid.radius, y: mapOrigin.y))
            let y = project(MKMapPoint(x: mapOrigin.x, y: mapOrigin.y + grid.radius))
            let radius = max(hypot(x.x - p.x, x.y - p.y), hypot(y.x - p.x, y.y - p.y))
            let ordered = covered.filter { id in
                let c = grid.center(of: id)
                let dx = (c.x - mapOrigin.x) / grid.radius, dy = (c.y - mapOrigin.y) / grid.radius
                let screen = CGPoint(x: p.x + dx * (x.x - p.x) + dy * (y.x - p.x),
                    y: p.y + dx * (x.y - p.y) + dy * (y.y - p.y))
                return bounds.insetBy(dx: -radius * 1.15, dy: -radius * 1.3).contains(screen)
            }.shuffled()
            // Scattered batches of five, with a small individual timing offset.
            // Even the last batch lands before the two-second deadline.
            let batches = max(1, (ordered.count + 4) / 5)
            for (rank, id) in ordered.enumerated() {
                let batch = Double(rank / 5) / Double(max(1, batches - 1))
                entryDelays[id] = batch * 1.25 + Double(MidnightHexGrid.seed(id) % 51) / 1_000
            }
        }
        return true
    }

    func finishEntryAnimation() { entryDelays.removeAll(keepingCapacity: true) }
    func invalidate() {
        valid = false; onChange = nil; covered.removeAll(); overviewSegments.removeAll(); finishEntryAnimation()
    }

    func contains(_ point: MKMapPoint) -> Bool {
        guard valid else { return false }
        if isOverview { return isRevealed(point) }
        let c = MidnightHexGrid().center(of: MidnightHexGrid().cell(at: CGPoint(x: point.x, y: point.y)))
        return isRevealed(MKMapPoint(x: c.x, y: c.y))
    }

    func tiles(time: TimeInterval = ProcessInfo.processInfo.systemUptime,
               reduceMotion: Bool = false) -> [Tile] {
        guard valid else { return [] }
        let grid = MidnightHexGrid()
        return covered.compactMap { id in
            let c = grid.center(of: id), center = localPoint(MKMapPoint(x: c.x, y: c.y))
            guard !reduceMotion, let delay = entryDelays[id] else {
                return Tile(id: id, center: center, radius: Self.localRadius, coverage: 1, fallProgress: nil)
            }
            let progress = (time - entryStartedAt - delay) / Self.fallDuration
            guard progress > 0 else { return nil }
            return Tile(id: id, center: center, radius: Self.localRadius,
                coverage: min(1, progress * 10), fallProgress: progress < 1 ? progress : nil)
        }
    }

    private func isRevealed(_ center: MKMapPoint) -> Bool {
        Self.isRevealed(center, index: index)
    }

    static func isRevealed(_ center: MKMapPoint, index: PaperSegmentIndex) -> Bool {
        let radius = TornPaperRenderer.revealRadiusMeters * MKMapPointsPerMeterAtLatitude(center.coordinate.latitude)
        let rect = MKMapRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let squaredRadius = radius * radius
        return index.segments(intersecting: rect).contains { segment in
            let dx = segment.end.x - segment.start.x, dy = segment.end.y - segment.start.y
            let t = min(1, max(0, ((center.x - segment.start.x) * dx + (center.y - segment.start.y) * dy)
                / max(0.000001, dx * dx + dy * dy)))
            let x = center.x - segment.start.x - t * dx, y = center.y - segment.start.y - t * dy
            return x * x + y * y <= squaredRadius
        }
    }
}

/// Pre-render a handful of matte, beveled pieces. Fine grain is baked once,
/// so drawing/animating hundreds of cells requires only cached image draws.
enum MidnightHexArtwork {
    // The base plane is drawn first. Raised pieces then paint in height order,
    // so their shadows land on neighboring pieces instead of disappearing
    // underneath whichever column MapKit happened to draw last.
    private static let lifts = [0.8, 3.4, 6.0, 8.3]
    private static let sprites: [[CGImage]] = lifts.map { lift in
        (0..<16).compactMap { makeSprite($0, lift: lift) }
    }
    private static let extent = 96.0
    private static let warmup: Void = {
        DispatchQueue.global(qos: .userInitiated).async { prepare() }
    }()

    static func prewarm() { _ = warmup }

    static var imageSideToRadius: Double { extent / 30 }

    static func prepare() { _ = sprites }

    static func image(for id: MidnightHexGrid.ID) -> CGImage? {
        let choices = sprites[tier(for: id)]
        return choices.isEmpty ? nil : choices[Int(MidnightHexGrid.seed(id) % UInt64(choices.count))]
    }

    static func height(for id: MidnightHexGrid.ID) -> Double { lifts[tier(for: id)] }

    static func basePath(for tile: MidnightHexSurface.Tile) -> CGPath {
        polygon(radius: tile.radius * 1.012, center: tile.center)
    }

    private static func tier(for id: MidnightHexGrid.ID) -> Int {
        switch (MidnightHexGrid.seed(id) >> 8) % 8 {
        case 0...2: return 0
        case 3...4: return 1
        case 5...6: return 2
        default: return 3
        }
    }

    /// Constant-sized pieces accelerate downwards, then make one small rebound.
    /// The result is in hex-radius units, independent of map render resolution.
    static func fallOffset(_ progress: Double?) -> Double {
        guard let progress, progress < 1 else { return 0 }
        if progress < 0.8 {
            return -3.6 * (1 - pow(max(0, progress) / 0.8, 2))
        }
        return -0.12 * sin((progress - 0.8) / 0.2 * .pi)
    }

    static func draw(_ tiles: [MidnightHexSurface.Tile], radiusScale: Double = 1,
                     project: (CGPoint) -> CGPoint, in context: CGContext) {
        let ordered = tiles.sorted {
            let a = lifts[tier(for: $0.id)] - fallOffset($0.fallProgress) * 30
            let b = lifts[tier(for: $1.id)] - fallOffset($1.fallProgress) * 30
            if a != b { return a < b }
            if $0.id.q != $1.id.q { return $0.id.q < $1.id.q }
            return $0.id.r < $1.id.r
        }
        context.setFillColor(CGColor(red: 0.035, green: 0.060, blue: 0.087, alpha: 1))
        for tile in ordered {
            let center = project(tile.center)
            let radius = tile.radius * radiusScale
            let contact = tile.fallProgress.map { min(1, max(0, ($0 - 0.7) / 0.3)) } ?? 1
            context.saveGState()
            context.setAlpha(min(1, tile.coverage * 1.8) * contact)
            context.translateBy(x: center.x, y: center.y)
            context.addPath(polygon(radius: radius * 1.012))
            context.fillPath()
            context.restoreGState()
        }
        for tile in ordered {
            drawPiece(tile, at: project(tile.center), radius: tile.radius * radiusScale, in: context)
        }
    }

    private static func drawPiece(_ tile: MidnightHexSurface.Tile, at center: CGPoint,
                                  radius: Double, in context: CGContext) {
        let choices = sprites[tier(for: tile.id)]
        guard !choices.isEmpty else { return }
        let image = choices[Int(MidnightHexGrid.seed(tile.id) % UInt64(choices.count))]
        let progress = tile.coverage
        let scale = radius / 30
        let side = extent * scale
        context.saveGState()
        context.setAlpha(min(1, progress * 1.8))
        context.translateBy(x: center.x, y: center.y + fallOffset(tile.fallProgress) * radius)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
        context.restoreGState()
    }

    private static func polygon(radius: Double, center: CGPoint = .zero) -> CGPath {
        let path = CGMutablePath()
        for i in 0..<6 {
            let angle = Double(i) * .pi / 3
            let p = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    private static func makeSprite(_ variant: Int, lift: Double) -> CGImage? {
        let scale = 2.5, size = Int(extent * scale)
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: extent / 2, y: extent / 2)
        let topCenter = CGPoint(x: -lift * 0.38, y: lift)
        let topRadius = 30.3 + lift * 0.035
        let shape = polygon(radius: topRadius, center: topCenter)
        // Slightly oversized, offset upper faces overlap the lower neighbors.
        // Their cast shadows are composited after those neighbors' faces.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0.8 + lift * 0.34, height: -1.2 - lift * 0.75),
            blur: 1.0 + lift * 0.30, color: CGColor(gray: 0, alpha: 0.82))
        ctx.setFillColor(CGColor(red: 0.035, green: 0.060, blue: 0.087, alpha: 1))
        ctx.addPath(shape); ctx.fillPath()
        ctx.restoreGState()

        // Extruded front walls join each raised face to its footprint. Different
        // wall lighting makes this read as thickness, rather than a second sheet.
        for edge in 3...5 {
            let a = Double(edge) * .pi / 3, b = Double(edge + 1) * .pi / 3
            let side = CGMutablePath()
            side.move(to: CGPoint(x: cos(a) * 30.15, y: sin(a) * 30.15))
            side.addLine(to: CGPoint(x: cos(b) * 30.15, y: sin(b) * 30.15))
            side.addLine(to: CGPoint(x: topCenter.x + cos(b) * topRadius, y: topCenter.y + sin(b) * topRadius))
            side.addLine(to: CGPoint(x: topCenter.x + cos(a) * topRadius, y: topCenter.y + sin(a) * topRadius))
            side.closeSubpath()
            let brightness = edge == 3 ? 1.15 : (edge == 4 ? 0.90 : 0.67)
            ctx.setFillColor(CGColor(red: 0.055 * brightness, green: 0.096 * brightness,
                blue: 0.137 * brightness, alpha: 1))
            ctx.addPath(side); ctx.fillPath()
        }

        ctx.saveGState()
        ctx.translateBy(x: topCenter.x, y: topCenter.y)
        ctx.scaleBy(x: topRadius / 29.3, y: topRadius / 29.3)

        ctx.saveGState()
        ctx.addPath(polygon(radius: 29.3)); ctx.clip()
        let shift = Double(variant % 5 - 2) * 0.004 + lift * 0.0012
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0.133 + shift, green: 0.207 + shift, blue: 0.272 + shift, alpha: 1),
            CGColor(red: 0.075 + shift, green: 0.127 + shift, blue: 0.182 + shift, alpha: 1)
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: -20, y: 26), end: CGPoint(x: 21, y: -29),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        var random = UInt64(variant + 1) &* 0x9E3779B185EBCA87
        for _ in 0..<3100 {
            random ^= random << 13; random ^= random >> 7; random ^= random << 17
            let x = Double(random & 0xffff) / 65535 * 60 - 30
            let y = Double((random >> 16) & 0xffff) / 65535 * 60 - 30
            let bright = (random >> 32) & 1 == 0
            ctx.setFillColor(CGColor(gray: bright ? 0.72 : 0.01, alpha: bright ? 0.055 : 0.17))
            ctx.fill(CGRect(x: x, y: y, width: 0.28, height: 0.4))
        }
        ctx.restoreGState()

        ctx.setLineWidth(0.55)
        ctx.setStrokeColor(CGColor(red: 0.28, green: 0.38, blue: 0.46, alpha: 0.62))
        ctx.move(to: CGPoint(x: -29.3, y: 0))
        ctx.addLine(to: CGPoint(x: -14.65, y: 25.375))
        ctx.addLine(to: CGPoint(x: 14.65, y: 25.375))
        ctx.addLine(to: CGPoint(x: 29.3, y: 0)); ctx.strokePath()
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.6))
        ctx.move(to: CGPoint(x: -29.3, y: 0))
        ctx.addLine(to: CGPoint(x: -14.65, y: -25.375))
        ctx.addLine(to: CGPoint(x: 14.65, y: -25.375))
        ctx.addLine(to: CGPoint(x: 29.3, y: 0)); ctx.strokePath()

        // Sparse embossed terrain marks, kept much quieter than real map POIs.
        if variant == 3 || variant == 11 {
            ctx.setShadow(offset: CGSize(width: 0.6, height: -1), blur: 0.6, color: CGColor(gray: 0, alpha: 0.8))
            ctx.setFillColor(CGColor(red: 0.09, green: 0.265, blue: 0.26, alpha: 0.72))
            let tree = CGMutablePath()
            tree.move(to: CGPoint(x: 0, y: 9))
            for p in [CGPoint(x: -4, y: 3), CGPoint(x: -2, y: 3), CGPoint(x: -5, y: -2),
                      CGPoint(x: -2, y: -2), CGPoint(x: -6, y: -6), CGPoint(x: 6, y: -6),
                      CGPoint(x: 2, y: -2), CGPoint(x: 5, y: -2), CGPoint(x: 2, y: 3), CGPoint(x: 4, y: 3)] {
                tree.addLine(to: p)
            }
            tree.closeSubpath(); ctx.addPath(tree); ctx.fillPath()
            ctx.fill(CGRect(x: -0.8, y: -9, width: 1.6, height: 4))
        } else if variant == 7 {
            ctx.setFillColor(CGColor(red: 0.035, green: 0.075, blue: 0.11, alpha: 0.8))
            for (x, h) in [(-5.0, 9.0), (3.0, 11.0)] {
                ctx.move(to: CGPoint(x: x, y: h - 4))
                ctx.addLine(to: CGPoint(x: x - 5, y: -6))
                ctx.addLine(to: CGPoint(x: x + 5, y: -6)); ctx.closePath(); ctx.fillPath()
            }
        }
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

/// Shared with the regression checks: group duration does not set child
/// durations. Every animated property must explicitly run for the whole fall.
enum MidnightHexPlacement {
    static func animation(center: CGPoint, radius: Double, restingHeight: Double,
                          beginTime: TimeInterval) -> CAAnimationGroup {
        let fall = CAKeyframeAnimation(keyPath: "position.y")
        fall.values = [center.y - radius * 3.6, center.y, center.y - radius * 0.12, center.y]
        fall.keyTimes = [0, 0.8, 0.9, 1]
        fall.timingFunctions = [CAMediaTimingFunction(name: .easeIn),
            CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 1, 1]
        opacity.keyTimes = [0, 0.10, 1]
        let depth = CAKeyframeAnimation(keyPath: "zPosition")
        depth.values = [restingHeight + 1000, restingHeight + 50, restingHeight, restingHeight]
        depth.keyTimes = [0, 0.75, 0.8, 1]
        let children = [fall, opacity, depth]
        children.forEach { $0.duration = MidnightHexSurface.fallDuration }
        let group = CAAnimationGroup()
        group.animations = children
        group.duration = MidnightHexSurface.fallDuration
        group.beginTime = beginTime
        group.fillMode = .backwards
        return group
    }
}

/// Background-rasterizable overview. No MapKit view calls or UIKit drawing.
enum MidnightHexOverview {
    // Periodic, geographically sized artwork only for extreme overviews where
    // individual world cells would number in the millions. Raster tiling does
    // not allocate one view, layer or draw job per geographic cell.
    private static let patternRadius = 48.0
    private static let patternSize = CGSize(width: 6 * patternRadius, height: 4 * sqrt(3) * patternRadius)
    private static let pattern: CGImage? = {
        let width = Int(ceil(patternSize.width)), height = Int(ceil(patternSize.height))
        guard let ctx = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: Double(height))
        ctx.scaleBy(x: Double(width) / patternSize.width, y: -Double(height) / patternSize.height)
        let grid = MidnightHexGrid()
        let worldSize = CGSize(width: patternSize.width * grid.radius / patternRadius,
            height: patternSize.height * grid.radius / patternRadius)
        let ids = grid.cells(in: CGRect(origin: .zero, size: worldSize))
        let tiles = ids.map { id -> MidnightHexSurface.Tile in
            let center = grid.center(of: id)
            // The periodic ID makes pieces just outside the image wrap with
            // the same height/variant as their matching piece on the other side.
            let q = ((id.q % 4) + 4) % 4
            let row = id.r + (id.q - q) / 2
            let wrapped = MidnightHexGrid.ID(q: q, r: ((row % 4) + 4) % 4, level: 10)
            return .init(id: wrapped, center: CGPoint(x: center.x * patternRadius / grid.radius,
                y: center.y * patternRadius / grid.radius), radius: patternRadius, coverage: 1, fallProgress: nil)
        }
        ctx.setFillColor(CGColor(red: 0.035, green: 0.060, blue: 0.087, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: patternSize))
        MidnightHexArtwork.draw(tiles, project: { $0 }, in: ctx)
        return ctx.makeImage()
    }()

    static func image(world: CGRect,
                      segments: [TornPaperRenderer.Segment], index: PaperSegmentIndex? = nil,
                      isCancelled: () -> Bool = { false }) -> CGImage? {
        guard !world.isEmpty, !world.isNull else { return nil }
        let scale = 1_200 / max(world.width, world.height)
        let width = max(1, Int(ceil(world.width * scale)))
        let height = max(1, Int(ceil(world.height * scale)))
        guard let ctx = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: Double(height))
        ctx.scaleBy(x: scale, y: -scale)
        let grid = MidnightHexGrid()
        let columns = ceil(world.width / (grid.radius * 1.5)) + 4
        let rows = ceil(world.height / (grid.radius * sqrt(3))) + 4
        if columns * rows <= 12_000 {
            // Same IDs, sprite variants, elevations and cell-shaped reveal as
            // the close view. Only the storage changes from layers to one image.
            let routeIndex = index ?? PaperSegmentIndex(segments: segments)
            var tiles: [MidnightHexSurface.Tile] = []
            for id in grid.cells(in: world) {
                if isCancelled() { return nil }
                let center = grid.center(of: id)
                guard !MidnightHexSurface.isRevealed(MKMapPoint(x: center.x, y: center.y), index: routeIndex) else { continue }
                tiles.append(.init(id: id, center: CGPoint(x: center.x - world.minX, y: center.y - world.minY),
                    radius: grid.radius, coverage: 1, fallProgress: nil))
            }
            MidnightHexArtwork.draw(tiles, project: { $0 }, in: ctx)
            return isCancelled() ? nil : ctx.makeImage()
        }
        // Far zoom retains hex artwork too, anchored to the very same world
        // lattice. Never replace it with a flat color or resize/rebase cells.
        guard let pattern, !isCancelled() else { return nil }
        let w = patternSize.width * grid.radius / patternRadius
        let h = patternSize.height * grid.radius / patternRadius
        let x = floor(world.minX / w) * w - world.minX
        let y = floor(world.minY / h) * h - world.minY
        ctx.saveGState()
        // Tiled image drawing uses image coordinates, unlike the y-down map canvas.
        ctx.translateBy(x: x, y: y + h)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(pattern, in: CGRect(x: 0, y: 0, width: w, height: h), byTiling: true)
        ctx.restoreGState()
        ctx.setBlendMode(.clear)
        let center = MKMapPoint(x: world.midX, y: world.midY)
        let radius = TornPaperRenderer.revealRadiusMeters * MKMapPointsPerMeterAtLatitude(center.coordinate.latitude)
        ctx.setLineWidth(max(1 / scale, radius * 2))
        ctx.setLineCap(.round)
        for segment in segments {
            if isCancelled() { return nil }
            ctx.move(to: CGPoint(x: segment.start.x - world.minX, y: segment.start.y - world.minY))
            ctx.addLine(to: CGPoint(x: segment.end.x - world.minX, y: segment.end.y - world.minY))
            // Clear each capsule separately. Combining hundreds of overlapping
            // routes into one stroked path triggers expensive path union work.
            ctx.strokePath()
        }
        return ctx.makeImage()
    }
}

#if canImport(UIKit)
import UIKit

/// A map-projected sibling of MapKit's content, below its native controls.
/// Core Animation moves only the pieces captured on entry; no display link
/// or per-frame route queries/MapKit overlay invalidations are needed.
final class MidnightHexMaskView: UIView {
    let surface: MidnightHexSurface
    private weak var mapView: MKMapView?
    private let canvas = CALayer()
    private let base = CAShapeLayer()
    private let overview = CALayer()
    private let overviewBase = CAShapeLayer()
    private let rasterQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var pieces: [MidnightHexGrid.ID: CALayer] = [:]
    private var lastCamera: [Double]?

    init(surface: MidnightHexSurface, mapView: MKMapView) {
        self.surface = surface
        self.mapView = mapView
        super.init(frame: mapView.bounds)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        isOpaque = false
        clipsToBounds = true
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        base.fillColor = CGColor(red: 0.035, green: 0.060, blue: 0.087, alpha: 1)
        canvas.anchorPoint = .zero
        canvas.position = .zero
        canvas.addSublayer(base)
        overviewBase.fillColor = CGColor(red: 0.055, green: 0.10, blue: 0.15, alpha: 1)
        overviewBase.fillRule = .evenOdd
        canvas.addSublayer(overviewBase)
        canvas.addSublayer(overview)
        layer.addSublayer(canvas)
        // This is a one-time immutable image cache, not work on animation frames.
        MidnightHexArtwork.prepare()
        surface.setCallback { [weak self] in self?.refreshViewport() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshViewport() {
        #if STREETPRINT_DIAGNOSTICS
        let timing = MapPerformanceProbe.begin("main.hexProjectionAndLayers")
        defer { MapPerformanceProbe.end(timing) }
        #endif
        guard let mapView, !bounds.isEmpty else { return }
        let rect = mapView.visibleMapRect
        let camera = [Double(bounds.width), Double(bounds.height), rect.minX, rect.minY,
            rect.width, rect.height, mapView.camera.heading, mapView.camera.pitch]
        guard surface.needsProjection || lastCamera != camera else { return }
        let isEntry = lastCamera == nil
        let geometryChanged = surface.updateViewport(bounds, unproject: { [unowned self, unowned mapView] point in
            MKMapPoint(mapView.convert(point, toCoordinateFrom: self))
        }, project: { [unowned self, unowned mapView] point in
            mapView.convert(point.coordinate, toPointTo: self)
        })
        lastCamera = camera
        let origin = surface.mapOrigin, unit = MidnightHexSurface.mapUnitsPerLocalPoint
        let p = mapView.convert(origin.coordinate, toPointTo: self)
        let x = mapView.convert(MKMapPoint(x: origin.x + unit, y: origin.y).coordinate, toPointTo: self)
        let y = mapView.convert(MKMapPoint(x: origin.x, y: origin.y + unit).coordinate, toPointTo: self)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.setAffineTransform(CGAffineTransform(a: x.x - p.x, b: x.y - p.y,
            c: y.x - p.x, d: y.y - p.y, tx: p.x, ty: p.y))
        CATransaction.commit()
        if geometryChanged {
            applyFrame(animateEntry: isEntry && !UIAccessibility.isReduceMotionEnabled)
        }
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        surface.contains(MKMapPoint(coordinate))
    }

    func finishEntryAnimation() {
        surface.finishEntryAnimation()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.removeAllAnimations()
        base.opacity = 1
        pieces.values.forEach { $0.removeAllAnimations() }
        CATransaction.commit()
    }

    private func applyFrame(animateEntry: Bool) {
        let tiles = surface.tiles(reduceMotion: true)
        let ids = Set(tiles.map(\.id))
        let removed = pieces.keys.filter { !ids.contains($0) }
        let path = CGMutablePath()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.isHidden = surface.isOverview
        overview.isHidden = !surface.isOverview
        overviewBase.isHidden = !surface.isOverview
        if surface.isOverview { updateOverview() }
        else { rasterQueue.cancelAllOperations() }
        for id in removed { pieces.removeValue(forKey: id)?.removeFromSuperlayer() }
        for tile in tiles {
            path.addPath(MidnightHexArtwork.basePath(for: tile))
            let piece = pieces[tile.id] ?? CALayer()
            if piece.superlayer == nil {
                pieces[tile.id] = piece
                piece.contents = MidnightHexArtwork.image(for: tile.id)
                piece.contentsScale = UIScreen.main.scale
                piece.contentsGravity = .resize
                canvas.addSublayer(piece)
                let side = tile.radius * MidnightHexArtwork.imageSideToRadius
                piece.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                piece.position = tile.center
                piece.opacity = 1
                piece.zPosition = 1 + MidnightHexArtwork.height(for: tile.id)
            }
            // Preserve the original placement on camera/layout/data refreshes.
            // Removing animations here was making entry look instantaneous.
        }
        base.path = path
        CATransaction.commit()

        guard animateEntry, !surface.entryDelays.isEmpty else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - surface.entryStartedAt
        let now = CACurrentMediaTime()
        for tile in tiles {
            guard let piece = pieces[tile.id], let delay = surface.entryDelays[tile.id] else { continue }
            let group = MidnightHexPlacement.animation(center: tile.center, radius: tile.radius,
                restingHeight: Double(piece.zPosition), beginTime: now + delay - elapsed)
            piece.add(group, forKey: "hex.entry")
        }
        let ground = CABasicAnimation(keyPath: "opacity")
        ground.fromValue = 0
        ground.toValue = 1
        ground.beginTime = now + 1.8 - elapsed
        ground.duration = 0.15
        ground.fillMode = .backwards
        base.add(ground, forKey: "hex.entry.base")
    }

    private func updateOverview() {
        let world = surface.renderBounds
        guard !world.isEmpty, !world.isNull else { return }
        let start = surface.localPoint(MKMapPoint(x: world.minX, y: world.minY))
        let unit = MidnightHexSurface.mapUnitsPerLocalPoint
        let rect = CGRect(x: start.x, y: start.y, width: world.width / unit, height: world.height / unit)
        // Fill only newly exposed canvas outside the previous raster. An
        // opaque full-size backing would also cover its transparent map holes.
        let pending = CGMutablePath()
        pending.addRect(rect)
        if overview.contents != nil {
            let overlap = rect.intersection(overview.frame)
            if !overlap.isNull { pending.addRect(overlap) }
        }
        overviewBase.path = pending
        let revision = surface.geometryRevision
        let segments = surface.overviewSegments
        let routeIndex = surface.segmentIndex
        rasterQueue.cancelAllOperations()
        let job = BlockOperation()
        job.addExecutionBlock { [weak self, weak job] in
            guard let job, !job.isCancelled else { return }
            #if STREETPRINT_DIAGNOSTICS
            let timing = MapPerformanceProbe.begin("worker.hexRaster")
            defer { MapPerformanceProbe.end(timing) }
            #endif
            let image = MidnightHexOverview.image(world: world, segments: segments, index: routeIndex,
                isCancelled: { job.isCancelled })
            guard !job.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !job.isCancelled,
                      self.surface.isOverview, self.surface.geometryRevision == revision else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.overview.frame = rect
                self.overview.contents = image
                self.overviewBase.path = nil
                CATransaction.commit()
            }
        }
        rasterQueue.addOperation(job)
    }

    deinit { rasterQueue.cancelAllOperations(); surface.setCallback(nil) }
}
#endif
