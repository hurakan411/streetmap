import CoreGraphics
import Foundation
import MapKit

/// Route-dependent paper cutout. Both texture and tear positions are anchored
/// to map coordinates; no fixed silhouette image is stretched over the map.
struct TornPaperRenderer {
    struct Segment {
        let start: MKMapPoint
        let end: MKMapPoint
    }

    static let revealRadiusMeters = 326.25
    private static let referenceWorldPixels = 16_777_216.0
    let segments: [Segment]
    let darkPaper: Bool
    let material: PaperMaterial?
    var edgeMaterial: PaperEdgeMaterial? = nil
    var segmentIndex: PaperSegmentIndex? = nil

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let point = MKMapPoint(coordinate)
        let factor = Self.referenceWorldPixels / MKMapSize.world.width
        let radius = (Self.revealRadiusMeters - Self.tearOffset(point.x * factor, point.y * factor))
            * MKMapPointsPerMeterAtLatitude(coordinate.latitude)
        return segments.contains {
            Self.distance(point.x, point.y, $0.start.x, $0.start.y, $0.end.x, $0.end.y) <= radius
        }
    }

    func render(
        at tile: MKTileOverlayPath,
        screenPointsPerTileUnit: Double,
        isCancelled: () -> Bool = { false }
    ) -> CGImage? {
        guard !isCancelled() else { return nil }
        let scale = min(3, max(0.5, Double(tile.contentScaleFactor)))
        let screenScale = min(2, max(0.5, screenPointsPerTileUnit))
        let size = Int(256 * scale)
        let worldPixels = 256 * pow(2, Double(tile.z))
        let originX = Double(tile.x) * 256, originY = Double(tile.y) * 256
        let mapUnitsPerPixel = MKMapSize.world.width / worldPixels
        let latitude = MKMapPoint(x: (originX + 128) * mapUnitsPerPixel,
            y: (originY + 128) * mapUnitsPerPixel).coordinate.latitude
        let pixelsPerMeter = MKMapPointsPerMeterAtLatitude(latitude) / mapUnitsPerPixel
        let radius = Self.revealRadiusMeters * pixelsPerMeter
        let searchRadius = radius + 20 * pixelsPerMeter + 64 / screenScale
        // Extra samples give adjoining tiles the same contour normals.
        let step = scale < 1 ? 4.0 : 2.0
        let padding = 4.0
        let gridSize = Int((256 + padding * 2) / step) + 1
        // Keep squared distances while visiting segments: one square root per
        // grid point, not per route/point pair. The immutable index avoids
        // scanning the entire history for every newly visible tile.
        var field = [Double](repeating: searchRadius * searchRadius, count: gridSize * gridSize)
        let query = MKMapRect(x: (originX - searchRadius - padding) * mapUnitsPerPixel,
            y: (originY - searchRadius - padding) * mapUnitsPerPixel,
            width: (256 + 2 * (searchRadius + padding)) * mapUnitsPerPixel,
            height: (256 + 2 * (searchRadius + padding)) * mapUnitsPerPixel)
        let nearby = segmentIndex?.segments(intersecting: query) ?? segments
        for segment in nearby {
            guard !isCancelled() else { return nil }
            let ax = segment.start.x / mapUnitsPerPixel - originX + padding
            let ay = segment.start.y / mapUnitsPerPixel - originY + padding
            let bx = segment.end.x / mapUnitsPerPixel - originX + padding
            let by = segment.end.y / mapUnitsPerPixel - originY + padding
            let minX = max(0, Int(floor((min(ax, bx) - searchRadius) / step)))
            let maxX = min(gridSize - 1, Int(ceil((max(ax, bx) + searchRadius) / step)))
            let minY = max(0, Int(floor((min(ay, by) - searchRadius) / step)))
            let maxY = min(gridSize - 1, Int(ceil((max(ay, by) + searchRadius) / step)))
            guard minX <= maxX, minY <= maxY else { continue }
            let dx = bx - ax, dy = by - ay
            let inverseLength = 1 / max(0.000001, dx * dx + dy * dy)
            for y in minY...maxY { for x in minX...maxX {
                let i = y * gridSize + x
                let px = Double(x) * step - ax, py = Double(y) * step - ay
                let t = Self.clamp((px * dx + py * dy) * inverseLength)
                let ex = px - t * dx, ey = py - t * dy
                field[i] = min(field[i], ex * ex + ey * ey)
            }}
        }
        let referenceFactor = Self.referenceWorldPixels / worldPixels
        for y in 0..<gridSize {
            let worldY = originY - padding + Double(y) * step
            let rowLatitude = MKMapPoint(x: (originX + 128) * mapUnitsPerPixel,
                y: worldY * mapUnitsPerPixel).coordinate.latitude
            let rowPixelsPerMeter = MKMapPointsPerMeterAtLatitude(rowLatitude) / mapUnitsPerPixel
            for x in 0..<gridSize {
                let nx = (originX - padding + Double(x) * step) * referenceFactor
                let ny = worldY * referenceFactor
                let i = y * gridSize + x
                field[i] = sqrt(field[i]) - (Self.revealRadiusMeters - Self.tearOffset(nx, ny)) * rowPixelsPerMeter
            }
        }
        let distances = PaperDistanceField(values: field, side: gridSize,
            step: step, padding: padding, screenScale: screenScale)

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let paper = darkPaper ? SIMD3(0.060, 0.079, 0.112)
            : SIMD3(205.0 / 255, 201.0 / 255, 194.0 / 255)
        let fibres = darkPaper ? SIMD3(0.17, 0.19, 0.22) : SIMD3(0.975, 0.963, 0.941)
        let fibreResolution = min(1, screenScale / max(0.001, referenceFactor))
        let curlScale = min(1, radius * screenScale / 30)
        let flatThreshold = max(14 * curlScale + 3,
            (edgeMaterial?.maximumEdgeOffset ?? 0) * curlScale + 11 * curlScale + 3)
        let aa = scale / screenScale
        for y in 0..<size {
            if y.isMultiple(of: 32), isCancelled() { return nil }
            let py = (Double(y) + 0.5) / scale
            for x in 0..<size {
                let px = (Double(x) + 0.5) / scale
                let distance = distances.distance(x: px, y: py)
                if distance < -32 * curlScale { continue }
                let nx = (originX + px) * referenceFactor
                let ny = (originY + py) * referenceFactor
                let sx = (originX + px) * screenScale, sy = (originY + py) * screenScale
                let grain = edgeMaterial?.surface(x: sx * 3.2, y: sy * 3.2)
                    ?? SIMD3(repeating: material?.sample(nx * 1.35, ny * 1.35) ?? 0)
                var face = paper + grain * (darkPaper ? 0.40 : 0.90)
                // Most covered pixels are flat paper. Do not run edge noise,
                // normal estimation, texture projection or shadow math there.
                if distance > flatThreshold {
                    let i = (y * size + x) * 4
                    for channel in 0..<3 {
                        pixels[i + channel] = UInt8((Self.clamp(face[channel]) * 255).rounded())
                    }
                    pixels[i + 3] = 255
                    continue
                }
                let sample = distances.sample(x: px, y: py)
                let fibreNoise = Self.noise(nx * 1.7 + ny * 0.31, ny * 1.9 - nx * 0.27)
                let tooth = Self.fractureNoise(nx * 0.28 + ny * 0.12, ny * 0.31 - nx * 0.10)
                let smallTear = Self.fractureNoise(nx * 0.72 - ny * 0.19, ny * 0.81 + nx * 0.17)
                let tear = distance + ((tooth - 0.5) * 3.6 + (smallTear - 0.5) * 1.2
                    + (fibreNoise - 0.5) * 0.5) * fibreResolution
                let planeCoverage = Self.clamp(tear * aa + 0.5)
                let fringeWidth = (0.25 + fibreNoise * 0.9) * curlScale
                let fringe = Self.clamp((tear + fringeWidth) * aa + 0.5) * (0.40 + fibreNoise * 0.5)
                let fibreWeight = fringe * (1 - planeCoverage)
                let lightFacing = max(0, -sample.normal.x * 0.55 - sample.normal.y * 0.83)
                let bx = nx - distance / screenScale * sample.normal.x * referenceFactor
                let by = ny - distance / screenScale * sample.normal.y * referenceFactor
                let liftNoise = Self.noise(bx * 0.030 + by * 0.008 + 59, by * 0.033 - bx * 0.009 - 17)
                let relief = PaperEdgeRelief(lift: Self.smoothstep(0.18, 0.82, liftNoise), scale: curlScale)
                let textureOffset = edgeMaterial?.edgeOffset(x: sx * 4, y: sy * 4,
                    normalX: sample.normal.x, normalY: sample.normal.y, scale: curlScale) ?? 0
                let actualTear = tear + textureOffset
                let slope = relief.slope(at: max(0, actualTear))
                let normalLength = sqrt(1 + slope * slope)
                let diffuse = max(0, (sample.normal.x * slope * 0.313
                    + sample.normal.y * slope * 0.452 + 0.835) / normalLength)
                // The same gray sheet gently rises at the break. There is no
                // folded-back tab or broad white back face around the opening.
                let illumination = min(1.04, max(0.95, (0.74 + diffuse * 0.32) / (0.74 + 0.835 * 0.32)))
                face *= illumination
                let coreWidth = (0.25 + tooth * 0.95) * curlScale
                let broken = pow(1 - Self.clamp(max(0, tear) / max(0.15, coreWidth)), 1.4)
                    * (0.40 + fibreNoise * 0.40)
                var surface = (face * (1 - broken) + fibres * broken) * planeCoverage + fibres * fibreWeight
                var coverage = planeCoverage + fibreWeight
                if let edgeMaterial, tear < 10 * curlScale {
                    let edge = edgeMaterial.edge(x: sx * 4, y: sy * 4, distance: tear,
                        normalX: sample.normal.x, normalY: sample.normal.y, scale: curlScale,
                        tint: paper, dark: darkPaper, includeShadows: false)
                    let weight = 1 - Self.smoothstep(4 * curlScale, 10 * curlScale, tear)
                    let litEdge = SIMD3(min(edge.w, edge.x * illumination), min(edge.w, edge.y * illumination),
                        min(edge.w, edge.z * illumination))
                    surface = surface * (1 - weight) + litEdge * weight
                    coverage = coverage * (1 - weight) + edge.w * weight
                }
                let shadow = actualTear < 0 ? relief.shadow(distance: max(0, -actualTear - fringeWidth),
                    lightFacing: lightFacing) : 0
                let shadowWeight = shadow * (1 - coverage)
                let alpha = coverage + shadowWeight
                let i = (y * size + x) * 4
                for channel in 0..<3 {
                    pixels[i + channel] = UInt8((Self.clamp(surface[channel]
                        + (darkPaper ? 0.015 : 0.17) * shadowWeight) * 255).rounded())
                }
                pixels[i + 3] = UInt8((Self.clamp(alpha) * 255).rounded())
            }
        }
        guard !isCancelled() else { return nil }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // Retained for comparison with the archived experiment. The current
    // renderer never calls this placement function or PaperCurlRasterizer.
    private static func makeFlaps(field: PaperDistanceField, originX: Double, originY: Double,
                                   referenceFactor: Double, screenScale: Double, curlScale: Double) -> [PaperCurlPatch] {
        let cell = 100.0
        let margin = 88 / screenScale
        let minX = Int(floor((originX - margin) * referenceFactor / cell))
        let maxX = Int(floor((originX + 256 + margin) * referenceFactor / cell))
        let minY = Int(floor((originY - margin) * referenceFactor / cell))
        let maxY = Int(floor((originY + 256 + margin) * referenceFactor / cell))
        var patches: [PaperCurlPatch] = []
        func project(_ guess: SIMD2<Double>) -> SIMD2<Double> {
            var p = guess
            for _ in 0..<4 {
                let value = field.sample(x: p.x, y: p.y)
                p -= field.smoothNormal(x: p.x, y: p.y) * value.distance / screenScale
            }
            return p
        }
        for cy in minY...maxY { for cx in minX...maxX {
            guard hash(cx + 431, cy - 117) > 0.15 else { continue }
            let seed = hash(cx - 23, cy + 71)
            let world = SIMD2((Double(cx) + 0.2 + hash(cx, cy) * 0.6) * cell,
                (Double(cy) + 0.2 + hash(cx + 9, cy - 37) * 0.6) * cell)
            let guess = world / referenceFactor - SIMD2(originX, originY)
            guard guess.x >= -margin, guess.x <= 256 + margin,
                  guess.y >= -margin, guess.y <= 256 + margin else { continue }
            let sample = field.sample(x: guess.x, y: guess.y)
            guard sample.distance > 1, sample.distance < cell / referenceFactor * screenScale * 0.65 else { continue }
            let anchor = project(guess)
            guard anchor.x >= -margin, anchor.x <= 256 + margin,
                  anchor.y >= -margin, anchor.y <= 256 + margin else { continue }
            let normal = field.smoothNormal(x: anchor.x, y: anchor.y)
            let tangent = SIMD2(-normal.y, normal.x)
            let halfWidth = (16 + seed * 14) * curlScale
            var boundary: [SIMD2<Double>] = [], normals: [SIMD2<Double>] = []
            var valid = false
            // A larger tab should not eliminate folds from curved edges.
            // Keep its lift/length, but taper its span to fit the local contour.
            for widthFactor in [1.0, 0.82, 0.66] {
                boundary.removeAll(keepingCapacity: true)
                normals.removeAll(keepingCapacity: true)
                valid = true
                for row in 0...32 {
                    let q = Double(row) / 16 - 1
                    let point = project(anchor + tangent * q * halfWidth * widthFactor / screenScale)
                    let n = field.smoothNormal(x: point.x, y: point.y)
                    guard n.x * normal.x + n.y * normal.y > 0.72 else { valid = false; break }
                    boundary.append(point * screenScale)
                    normals.append(n)
                }
                if valid { break }
            }
            guard valid else { continue }
            patches.append(PaperCurlPatch(boundary: boundary, normals: normals,
                length: (22 + hash(cx + 93, cy - 51) * 14) * curlScale,
                angle: 2.05 + seed * 0.45, seed: seed,
                textureOrigin: SIMD2(originX * screenScale, originY * screenScale)))
        }}
        return patches
    }

    /// Dense, narrow occlusion at the underside plus a softer directional
    /// tail. Both fall monotonically away from the paper (no offset peak).
    static func edgeShadow(distance: Double, lift: Double, lightFacing: Double, scale: Double) -> Double {
        let q = max(0, distance), amount = clamp(lift), facing = clamp(lightFacing)
        let curlHeight = Self.curlHeight(lift: amount, scale: scale)
        let falloff = max(0.25, (0.65 * scale + curlHeight * 0.55) * (0.65 + facing * 0.35))
        guard q < falloff * 5 else { return 0 }
        let contact = exp(-q / max(0.25, (0.85 + amount * 1.05) * scale))
            * (0.16 + amount * 0.42) * (0.65 + facing * 0.35)
        let cast = exp(-q / falloff) * (0.01 + amount * 0.045 + (0.03 + amount * 0.31) * facing)
        return 1 - (1 - contact) * (1 - cast)
    }

    private static func curlHeight(lift: Double, scale: Double) -> Double {
        (0.35 + lift * 12.0) * scale
    }

    private static func distance(_ x: Double, _ y: Double, _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
        let dx = bx - ax, dy = by - ay
        let t = clamp(((x - ax) * dx + (y - ay) * dy) / max(0.000001, dx * dx + dy * dy))
        return hypot(x - ax - t * dx, y - ay - t * dy)
    }

    private static func tearOffset(_ x: Double, _ y: Double) -> Double {
        // Quiet larger tears plus medium irregularity, no polygonal rock chips.
        (noise(x * 0.048 + y * 0.012, y * 0.055 - x * 0.015) - 0.5) * 18
            + (noise(x * 0.19 - y * 0.06, y * 0.17 + x * 0.04) - 0.5) * 5
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    private static func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let t = clamp((value - low) / max(0.0001, high - low))
        return t * t * (3 - 2 * t)
    }
    private static func hash(_ x: Int, _ y: Int) -> Double {
        var v = UInt64(bitPattern: Int64(x)) &* 0x9E3779B97F4A7C15 ^ UInt64(bitPattern: Int64(y)) &* 0xBF58476D1CE4E5B9
        v = (v ^ (v >> 30)) &* 0xBF58476D1CE4E5B9
        v = (v ^ (v >> 27)) &* 0x94D049BB133111EB
        return Double((v ^ (v >> 31)) & 0xFFFF) / 65535
    }
    private static func noise(_ x: Double, _ y: Double) -> Double {
        let ix = Int(floor(x)), iy = Int(floor(y))
        var fx = x - floor(x), fy = y - floor(y)
        fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy)
        let top = hash(ix, iy) * (1 - fx) + hash(ix + 1, iy) * fx
        let bottom = hash(ix, iy + 1) * (1 - fx) + hash(ix + 1, iy + 1) * fx
        return top * (1 - fy) + bottom * fy
    }

    private static func fractureNoise(_ x: Double, _ y: Double) -> Double {
        let ix = Int(floor(x)), iy = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
        let a = hash(ix, iy), b = hash(ix + 1, iy), c = hash(ix, iy + 1), d = hash(ix + 1, iy + 1)
        return fx + fy < 1 ? a + fx * (b - a) + fy * (c - a)
            : d + (1 - fx) * (c - d) + (1 - fy) * (b - d)
    }
}

/// Immutable bounding-volume tree shared by all tile jobs for one route set.
/// Long train segments are supported without populating thousands of grid cells.
final class PaperSegmentIndex {
    private indirect enum Node {
        case leaf(MKMapRect, [TornPaperRenderer.Segment])
        case branch(MKMapRect, Node, Node)

        var bounds: MKMapRect {
            switch self { case .leaf(let bounds, _), .branch(let bounds, _, _): return bounds }
        }

        func collect(in rect: MKMapRect, into result: inout [TornPaperRenderer.Segment]) {
            guard bounds.intersects(rect) else { return }
            switch self {
            case .leaf(_, let segments): result.append(contentsOf: segments)
            case .branch(_, let left, let right):
                left.collect(in: rect, into: &result)
                right.collect(in: rect, into: &result)
            }
        }
    }

    private let root: Node?

    init(segments: [TornPaperRenderer.Segment]) {
        func build(_ items: [TornPaperRenderer.Segment]) -> Node {
            let minX = items.reduce(Double.infinity) { min($0, $1.start.x, $1.end.x) }
            let minY = items.reduce(Double.infinity) { min($0, $1.start.y, $1.end.y) }
            let maxX = items.reduce(-Double.infinity) { max($0, $1.start.x, $1.end.x) }
            let maxY = items.reduce(-Double.infinity) { max($0, $1.start.y, $1.end.y) }
            // Nonzero bounds also include horizontal/vertical/point segments.
            let bounds = MKMapRect(x: minX, y: minY, width: max(0.001, maxX - minX), height: max(0.001, maxY - minY))
            guard items.count > 16 else { return .leaf(bounds, items) }
            let sorted = items.sorted {
                bounds.width >= bounds.height ? $0.start.x + $0.end.x < $1.start.x + $1.end.x
                    : $0.start.y + $0.end.y < $1.start.y + $1.end.y
            }
            let mid = sorted.count / 2
            return .branch(bounds, build(Array(sorted[..<mid])), build(Array(sorted[mid...])))
        }
        root = segments.isEmpty ? nil : build(segments)
    }

    func segments(intersecting rect: MKMapRect) -> [TornPaperRenderer.Segment] {
        var result: [TornPaperRenderer.Segment] = []
        root?.collect(in: rect, into: &result)
        return result
    }
}

struct PaperTileKey: Hashable {
    let x: Int
    let y: Int
    let z: Int

    var rect: MKMapRect {
        let side = MKMapSize.world.width / pow(2, Double(z))
        return MKMapRect(x: Double(x) * side, y: Double(y) * side, width: side, height: side)
    }
    var parent: PaperTileKey { .init(x: x / 2, y: y / 2, z: z - 1) }
    var cacheKey: NSString { "\(z)/\(x)/\(y)" as NSString }

    static func level(zoomScale: Double) -> Int {
        min(22, max(0, Int(floor(log2(max(1e-12, zoomScale) * MKMapSize.world.width / 256)))))
    }

    static func covering(_ rect: MKMapRect, level: Int, margin: Int = 0) -> [PaperTileKey] {
        let side = MKMapSize.world.width / pow(2, Double(level)), limit = (1 << level) - 1
        let minX = max(0, Int(floor(rect.minX / side)) - margin)
        let maxX = min(limit, Int(floor(rect.maxX / side)) + margin)
        let minY = max(0, Int(floor(rect.minY / side)) - margin)
        let maxY = min(limit, Int(floor(rect.maxY / side)) + margin)
        guard minX <= maxX, minY <= maxY else { return [] }
        return (minY...maxY).flatMap { y in (minX...maxX).map { .init(x: $0, y: y, z: level) } }
    }
}

/// Progressive, coalesced CGImage jobs. No PNG encode/decode, UI-thread render,
/// duplicate jobs, or backlog of tiles from an obsolete viewport.
final class PaperTilePipeline {
    private final class Tile {
        let image: CGImage
        let final: Bool
        init(_ image: CGImage, final: Bool) { self.image = image; self.final = final }
    }
    private struct Job { let id: UUID; let operation: BlockOperation; let final: Bool }
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "StreetPrint.PaperImages"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let paper: TornPaperRenderer
    private let scale: Double
    private let cache = NSCache<NSString, Tile>()
    private let lock = NSLock()
    private var jobs: [PaperTileKey: Job] = [:]
    private var wanted: Set<PaperTileKey> = []
    private var visible: Set<PaperTileKey> = []
    private var valid = true
    private var callback: ((MKMapRect) -> Void)?

    init(paper: TornPaperRenderer, scale: Double) {
        self.paper = paper
        self.scale = min(2, max(1, scale))
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func setCallback(_ callback: @escaping (MKMapRect) -> Void) {
        lock.lock(); self.callback = callback; lock.unlock()
    }

    func image(for key: PaperTileKey) -> CGImage? { cache.object(forKey: key.cacheKey)?.image }

    func request(_ key: PaperTileKey) {
        lock.lock(); defer { lock.unlock() }
        scheduleLocked(key)
    }

    func updateViewport(_ rect: MKMapRect, zoomScale: Double) {
        #if STREETPRINT_DIAGNOSTICS
        let timing = MapPerformanceProbe.begin("main.paperTileSchedule")
        defer { MapPerformanceProbe.end(timing) }
        #endif
        let level = PaperTileKey.level(zoomScale: zoomScale)
        let shown = Set(PaperTileKey.covering(rect, level: level))
        let neighbors = Set(PaperTileKey.covering(rect, level: level, margin: 1))
        // Keep adjacent zoom previews ready before a pinch requests them.
        var desired = neighbors
        if level > 0 { desired.formUnion(PaperTileKey.covering(rect, level: level - 1)) }
        if level < 22 { desired.formUnion(PaperTileKey.covering(rect, level: level + 1)) }
        lock.lock()
        defer { lock.unlock() }
        guard valid else { return }
        if desired == wanted && shown == visible { return }
        wanted = desired; visible = shown
        for key in Array(jobs.keys) where !desired.contains(key) || (jobs[key]!.final && !shown.contains(key)) {
            jobs.removeValue(forKey: key)?.operation.cancel()
        }
        let center = MKMapPoint(x: rect.midX, y: rect.midY)
        let ordered = desired.sorted {
            if shown.contains($0) != shown.contains($1) { return shown.contains($0) }
            return hypot($0.rect.midX - center.x, $0.rect.midY - center.y)
                < hypot($1.rect.midX - center.x, $1.rect.midY - center.y)
        }
        for key in ordered { scheduleLocked(key) }
    }

    private func scheduleLocked(_ key: PaperTileKey) {
        guard valid, wanted.contains(key) else { return }
        let cached = cache.object(forKey: key.cacheKey)
        let final = cached != nil
        guard cached?.final != true, !final || visible.contains(key) else { return }
        if let job = jobs[key] {
            job.operation.queuePriority = job.final ? .low : (visible.contains(key) ? .veryHigh : .normal)
            return
        }
        let operation = BlockOperation(), id = UUID()
        operation.queuePriority = final ? .low : (visible.contains(key) ? .veryHigh : .normal)
        jobs[key] = Job(id: id, operation: operation, final: final)
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self, let operation, !operation.isCancelled else { return }
            autoreleasepool {
                #if STREETPRINT_DIAGNOSTICS
                let timing = MapPerformanceProbe.begin("worker.paperTileRaster")
                defer { MapPerformanceProbe.end(timing) }
                #endif
                let path = MKTileOverlayPath(x: key.x, y: key.y, z: key.z,
                    contentScaleFactor: final ? self.scale : 0.5)
                let image = self.paper.render(at: path, screenPointsPerTileUnit: 1,
                    isCancelled: { operation.isCancelled })
                self.lock.lock()
                guard self.valid, !operation.isCancelled, self.jobs[key]?.id == id else {
                    self.lock.unlock(); return
                }
                self.jobs.removeValue(forKey: key)
                if let image {
                    self.cache.setObject(Tile(image, final: final), forKey: key.cacheKey,
                        cost: image.bytesPerRow * image.height)
                }
                let callback = image == nil ? nil : self.callback
                if image != nil && !final { self.scheduleLocked(key) }
                self.lock.unlock()
                callback?(key.rect)
            }
        }
        Self.queue.addOperation(operation)
    }

    func invalidate() {
        lock.lock()
        valid = false; callback = nil
        jobs.values.forEach { $0.operation.cancel() }
        jobs.removeAll(); wanted.removeAll(); visible.removeAll()
        lock.unlock()
        cache.removeAllObjects()
    }

    deinit { invalidate() }
}

/// A shallow edge lift attached to a single unbroken sheet. Its maximum bend
/// remains below 90°, so it cannot make a loop or expose another broad layer.
struct PaperEdgeRelief {
    let lift: Double
    let scale: Double
    var height: Double { (0.8 + lift * 6.0) * scale }
    var width: Double { (4.0 + lift * 6.5) * scale }

    func elevation(at distance: Double) -> Double {
        let t = max(0, 1 - max(0, distance) / max(0.01, width))
        return height * t * t * t
    }

    func slope(at distance: Double) -> Double {
        let t = max(0, 1 - max(0, distance) / max(0.01, width))
        return -3 * height / max(0.01, width) * t * t
    }

    func shadow(distance: Double, lightFacing: Double) -> Double {
        let q = max(0, distance), facing = min(1, max(0, lightFacing))
        guard q < 20 * scale else { return 0 }
        let contact = exp(-q / max(0.2, (0.45 + lift * 0.25) * scale)) * (0.25 + lift * 0.11)
        let reach = max(0.25, (0.8 * scale + height * 0.70) * (0.40 + facing * 0.60))
        let cast = exp(-q / reach) * (0.10 + facing * 0.45) * (0.65 + lift * 0.35)
        return 1 - (1 - contact) * (1 - cast)
    }
}

private struct PaperDistanceField {
    struct Sample { let distance: Double; let normal: SIMD2<Double> }
    let values: [Double]
    let side: Int
    let step: Double
    let padding: Double
    let screenScale: Double

    func distance(x: Double, y: Double) -> Double {
        let gx = min(Double(side - 1) - 0.000001, max(0, (x + padding) / step))
        let gy = min(Double(side - 1) - 0.000001, max(0, (y + padding) / step))
        let ix = Int(gx), iy = Int(gy), fx = gx - Double(ix), fy = gy - Double(iy)
        let a = iy * side + ix
        let top = values[a] + (values[a + 1] - values[a]) * fx
        let bottom = values[a + side] + (values[a + side + 1] - values[a + side]) * fx
        return (top + (bottom - top) * fy) * screenScale
    }

    func sample(x: Double, y: Double) -> Sample {
        let gx = min(Double(side - 1) - 0.000001, max(0, (x + padding) / step))
        let gy = min(Double(side - 1) - 0.000001, max(0, (y + padding) / step))
        let ix = Int(gx), iy = Int(gy), fx = gx - Double(ix), fy = gy - Double(iy)
        let a = iy * side + ix, b = a + 1, c = a + side, d = c + 1
        let top = values[a] + (values[b] - values[a]) * fx
        let bottom = values[c] + (values[d] - values[c]) * fx
        let dx = ((values[b] - values[a]) * (1 - fy) + (values[d] - values[c]) * fy) / step
        let dy = (bottom - top) / step
        let length = max(0.00001, hypot(dx, dy))
        return Sample(distance: (top + (bottom - top) * fy) * screenScale,
            normal: SIMD2(dx / length, dy / length))
    }

    func smoothNormal(x: Double, y: Double) -> SIMD2<Double> {
        let h = 2.5 / screenScale
        let dx = sample(x: x + h, y: y).distance - sample(x: x - h, y: y).distance
        let dy = sample(x: x, y: y + h).distance - sample(x: x, y: y - h).distance
        return SIMD2(dx, dy) / max(0.00001, hypot(dx, dy))
    }
}

struct PaperCurlVertex {
    var position: SIMD3<Double>
    var normal: SIMD3<Double>
    let uv: SIMD2<Double>
    let progress: Double
}

/// A connected, two-sided curved sheet, in screen-point coordinates. Each
/// cross-section starts flat at its hinge and bends through more than 90°.
/// Orthographic depth testing then exposes the back at the folded free end.
struct PaperCurlPatch {
    let vertices: [PaperCurlVertex]
    let triangles: [(Int, Int, Int)]
    let cuts: [(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)]

    init(boundary: [SIMD2<Double>], normals: [SIMD2<Double>], length: Double,
         angle: Double, seed: Double, textureOrigin: SIMD2<Double>) {
        let along = 40, stride = along + 1
        var points: [PaperCurlVertex] = [], cuts: [(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)] = []
        var hinges: [SIMD2<Double>] = []
        for row in boundary.indices {
            let q = Double(row) / Double(boundary.count - 1) * 2 - 1
            // An asymmetric tapered tear, rather than a symmetric rolled cuff.
            let u = seed < 0.5 ? (q + 1) / 2 : (1 - q) / 2
            let taper = min(1, pow(max(0, u), 0.65) * pow(max(0, 1 - u), 1.35) / 0.283)
            let stripLength = length * taper * (0.95 + 0.05 * cos(q * 8 + seed * 9))
            let theta = angle + (u - 0.5) * 0.24 + sin(q * 7 + seed * 6) * 0.04
            let radius = stripLength / theta
            let n = normals[row]
            hinges.append(boundary[row] + n * stripLength)
            for col in 0...along {
                let progress = Double(col) / Double(along)
                let bend = theta * progress
                let r = stripLength - radius * sin(bend)
                let z = radius * (1 - cos(bend))
                let flat = boundary[row] + n * stripLength * (1 - progress)
                let xy = boundary[row] + n * r
                points.append(PaperCurlVertex(position: SIMD3(xy.x, xy.y, z),
                    normal: SIMD3(n.x * sin(bend), n.y * sin(bend), cos(bend)),
                    uv: (textureOrigin + flat) * 3.2, progress: progress))
            }
        }
        var triangles: [(Int, Int, Int)] = []
        for row in 0..<(boundary.count - 1) {
            cuts.append((boundary[row], hinges[row], boundary[row + 1]))
            cuts.append((hinges[row], hinges[row + 1], boundary[row + 1]))
            for col in 0..<along {
                let a = row * stride + col, b = a + 1, c = a + stride, d = c + 1
                triangles.append((a, c, b)); triangles.append((b, c, d))
            }
        }
        // Surface normals include the varying width of the tab as well as its
        // cylindrical bend; illumination follows the actual triangle geometry.
        for row in boundary.indices {
            for col in 0...along {
                if col == 0 {
                    // The analytic tangent at the hinge is exactly flat.
                    // A one-sided finite difference tilts it at narrow tips.
                    points[row * stride].normal = SIMD3(0, 0, 1)
                    continue
                }
                let left = max(0, row - 1) * stride + col
                let right = min(boundary.count - 1, row + 1) * stride + col
                let before = row * stride + max(0, col - 1)
                let after = row * stride + min(along, col + 1)
                let u = points[right].position - points[left].position
                let v = points[after].position - points[before].position
                let cross = SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
                let magnitude = sqrt(cross.x * cross.x + cross.y * cross.y + cross.z * cross.z)
                if magnitude > 0.00001 { points[row * stride + col].normal = cross / magnitude }
            }
        }
        vertices = points; self.triangles = triangles; self.cuts = cuts
    }
}

private struct PaperCurlRasterizer {
    let flaps: [PaperCurlPatch]
    let size: Int
    let pixelsPerPoint: Double
    let paper: SIMD3<Double>
    let dark: Bool
    let material: PaperEdgeMaterial?

    func render(into pixels: inout [UInt8]) {
        guard !flaps.isEmpty else { return }
        // Cut away the exact flat strip which was bent into each mesh. The
        // hinge and its UVs coincide with the original sheet at z = 0.
        for flap in flaps { for (a, b, c) in flap.cuts {
            Self.raster(a * pixelsPerPoint, b * pixelsPerPoint, c * pixelsPerPoint, side: size) { x, y, _, _, _ in
                let i = (y * size + x) * 4
                for channel in 0..<4 { pixels[i + channel] = 0 }
            }
        }}
        drawShadows(into: &pixels)
        var depth = [Double](repeating: -.infinity, count: size * size)
        let light = SIMD3(-0.313, -0.452, 0.835)
        for flap in flaps { for (ia, ib, ic) in flap.triangles {
            let a = flap.vertices[ia], b = flap.vertices[ib], c = flap.vertices[ic]
            let pa = SIMD2(a.position.x, a.position.y) * pixelsPerPoint
            let pb = SIMD2(b.position.x, b.position.y) * pixelsPerPoint
            let pc = SIMD2(c.position.x, c.position.y) * pixelsPerPoint
            Self.raster(pa, pb, pc, side: size) { x, y, wa, wb, wc in
                let i = y * size + x
                let z = a.position.z * wa + b.position.z * wb + c.position.z * wc
                guard z >= depth[i] else { return }
                depth[i] = z
                var normal = a.normal * wa + b.normal * wb + c.normal * wc
                let back = normal.z < 0
                if back { normal = -normal }
                let magnitude = max(0.00001, sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z))
                normal /= magnitude
                let diffuse = max(0, normal.x * light.x + normal.y * light.y + normal.z * light.z)
                let illumination = 0.55 + diffuse * 0.54
                let uv = a.uv * wa + b.uv * wb + c.uv * wc
                let grain = material?.surface(x: uv.x, y: uv.y) ?? .zero
                let backColor = dark ? paper + SIMD3(repeating: 0.06) : SIMD3(0.947, 0.931, 0.901)
                var color = ((back ? backColor : paper) + grain * (dark ? 0.4 : 0.9)) * illumination
                let progress = a.progress * wa + b.progress * wb + c.progress * wc
                // Only the very thin broken free edge exposes white fibres.
                let tip = max(0, (progress - 0.985) / 0.015) * 0.30
                let fiber = dark ? SIMD3(repeating: 0.23) : SIMD3(0.975, 0.963, 0.941)
                color = color * (1 - tip) + fiber * tip
                for channel in 0..<3 { pixels[i * 4 + channel] = UInt8((min(1, max(0, color[channel])) * 255).rounded()) }
                pixels[i * 4 + 3] = 255
            }
        }}
    }

    private func drawShadows(into pixels: inout [UInt8]) {
        // Project every triangle onto the map/paper plane from the same light
        // used for surface shading. Penumbra grows with the occluder's height.
        let margin = 28.0
        let side = Int(ceil(Double(size) / pixelsPerPoint + margin * 2))
        var bands = [[Float]](repeating: [Float](repeating: 0, count: side * side), count: 3)
        for flap in flaps { for (ia, ib, ic) in flap.triangles {
            let a = flap.vertices[ia].position, b = flap.vertices[ib].position, c = flap.vertices[ic].position
            func project(_ p: SIMD3<Double>) -> SIMD2<Double> {
                SIMD2(p.x + 0.375 * p.z + margin, p.y + 0.542 * p.z + margin)
            }
            Self.raster(project(a), project(b), project(c), side: side) { x, y, wa, wb, wc in
                let height = a.z * wa + b.z * wb + c.z * wc
                guard height > 0.08 else { return }
                let band = height < 3 ? 0 : (height < 8 ? 1 : 2)
                let opacity = Float(0.68 / (1 + height * 0.025))
                bands[band][y * side + x] = max(bands[band][y * side + x], opacity)
            }
        }}
        for band in 0..<3 {
            // Two box filters approximate a Gaussian without a GPU context or
            // main-thread work. The padded world-space image avoids tile seams.
            bands[band] = Self.blur(Self.blur(bands[band], side: side, radius: band + 1), side: side, radius: band + 1)
        }
        for y in 0..<size { for x in 0..<size {
            let gx = (Double(x) + 0.5) / pixelsPerPoint + margin - 0.5
            let gy = (Double(y) + 0.5) / pixelsPerPoint + margin - 0.5
            let ix = min(side - 2, Int(gx)), iy = min(side - 2, Int(gy))
            let fx = Float(gx - Double(ix)), fy = Float(gy - Double(iy))
            var alpha: Float = 0
            for band in bands {
                let top = band[iy * side + ix] * (1 - fx) + band[iy * side + ix + 1] * fx
                let bottom = band[(iy + 1) * side + ix] * (1 - fx) + band[(iy + 1) * side + ix + 1] * fx
                alpha = max(alpha, top * (1 - fy) + bottom * fy)
            }
            guard alpha > 0.001 else { continue }
            let i = (y * size + x) * 4, a = Double(alpha)
            let shade = dark ? SIMD3(repeating: 0.012) : SIMD3(0.16, 0.145, 0.12)
            for channel in 0..<3 {
                pixels[i + channel] = UInt8((min(255, Double(pixels[i + channel]) * (1 - a) + shade[channel] * a * 255)).rounded())
            }
            pixels[i + 3] = UInt8(min(255, (Double(pixels[i + 3]) * (1 - a) + a * 255).rounded()))
        }}
    }

    private static func raster(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, side: Int,
                               pixel: (Int, Int, Double, Double, Double) -> Void) {
        let area = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
        guard abs(area) > 0.000001 else { return }
        let minX = max(0, Int(floor(min(a.x, min(b.x, c.x)))))
        let maxX = min(side - 1, Int(ceil(max(a.x, max(b.x, c.x)))))
        let minY = max(0, Int(floor(min(a.y, min(b.y, c.y)))))
        let maxY = min(side - 1, Int(ceil(max(a.y, max(b.y, c.y)))))
        guard minX <= maxX, minY <= maxY else { return }
        for y in minY...maxY { for x in minX...maxX {
            let px = Double(x) + 0.5, py = Double(y) + 0.5
            let wa = ((b.y - c.y) * (px - c.x) + (c.x - b.x) * (py - c.y)) / area
            let wb = ((c.y - a.y) * (px - c.x) + (a.x - c.x) * (py - c.y)) / area
            let wc = 1 - wa - wb
            if wa >= -0.000001 && wb >= -0.000001 && wc >= -0.000001 { pixel(x, y, wa, wb, wc) }
        }}
    }

    private static func blur(_ input: [Float], side: Int, radius: Int) -> [Float] {
        var horizontal = input, output = input
        let divisor = Float(radius * 2 + 1)
        for y in 0..<side {
            var sum: Float = 0
            for x in -radius...radius { sum += input[y * side + max(0, x)] }
            for x in 0..<side {
                horizontal[y * side + x] = sum / divisor
                sum += input[y * side + min(side - 1, x + radius + 1)] - input[y * side + max(0, x - radius)]
            }
        }
        for x in 0..<side {
            var sum: Float = 0
            for y in -radius...radius { sum += horizontal[max(0, y) * side + x] }
            for y in 0..<side {
                output[y * side + x] = sum / divisor
                sum += horizontal[min(side - 1, y + radius + 1) * side + x] - horizontal[max(0, y - radius) * side + x]
            }
        }
        return output
    }
}

/// Decodes a thin frayed-paper material. The current renderer samples its
/// surface and fine break, discards baked shadows, and shades a shallow edge
/// lift with PaperEdgeRelief. Larger folded-tab assets remain archived.
struct PaperEdgeMaterial {
    private let pixels: [UInt8]
    private let width: Int
    private let height: Int
    private let boundary: Double
    private let edgeRows: [Double]
    private let paperMean: SIMD3<Double>
    private let surfaceHeight: Int
    let maximumEdgeOffset: Double

    init?(image: CGImage) {
        width = image.width
        height = image.height
        guard width > 4, height > 4 else { return nil }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let valid = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard valid else { return nil }
        // Core Graphics buffers are normalized here to paper at the top.
        if data[3] < data[(height - 1) * width * 4 + 3] {
            let original = data
            for y in 0..<height {
                let from = (height - 1 - y) * width * 4
                data.replaceSubrange((y * width * 4)..<((y + 1) * width * 4),
                    with: original[from..<(from + width * 4)])
            }
        }
        var sumY = 0.0, count = 0.0
        var rows = [Double](repeating: Double(height) / 2, count: width)
        for x in 0..<width {
            for y in (height / 4)..<(height * 3 / 4) {
                if data[(y * width + x) * 4 + 3] < 230 {
                    sumY += Double(y); count += 1; rows[x] = Double(y); break
                }
            }
        }
        guard count > 0 else { return nil }
        boundary = sumY / count
        edgeRows = rows
        maximumEdgeOffset = rows.map { abs($0 - sumY / count) }.max()! / 4
        surfaceHeight = max(2, Int(boundary * 0.64))
        var mean = SIMD3<Double>(repeating: 0), samples = 0.0
        for y in stride(from: 8, to: surfaceHeight, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let p = (y * width + x) * 4
                mean += SIMD3(Double(data[p]), Double(data[p + 1]), Double(data[p + 2])) / 255
                samples += 1
            }
        }
        paperMean = mean / max(1, samples)
        pixels = data
    }

    func surface(x: Double, y: Double) -> SIMD3<Double> {
        let row = Self.mirror(y, length: surfaceHeight)
        let color = sample(x: x, y: row)
        return SIMD3(color.x, color.y, color.z) - paperMean
    }

    func edgeOffset(x: Double, y: Double, normalX: Double, normalY: Double, scale: Double) -> Double {
        func row(_ u: Double) -> Double {
            let sx = Self.mirror(u, length: width), ix = min(width - 2, Int(sx)), f = sx - Double(ix)
            return edgeRows[ix] * (1 - f) + edgeRows[ix + 1] * f
        }
        let wx = pow(abs(normalX), 6), wy = pow(abs(normalY), 6)
        let vertical = wx / max(0.000001, wx + wy)
        return (row(y + 217) * vertical + row(x) * (1 - vertical) - boundary) * scale / 4
    }

    func edge(x: Double, y: Double, distance: Double, normalX: Double, normalY: Double,
              scale: Double, tint: SIMD3<Double>, dark: Bool, includeShadows: Bool = true) -> SIMD4<Double> {
        let extent = max(0.2, scale)
        // Image-generated alpha can include very faint pixels well outside
        // the photographed edge. Bound the material spatially so these never
        // leave haze over open routes or translucency inside the sheet.
        if distance <= -24 * extent { return .zero }
        if distance >= 28 * extent {
            let grain = surface(x: x * 0.8, y: y * 0.8) * (dark ? 0.40 : 0.90)
            return SIMD4(min(1, max(0, tint.x + grain.x)), min(1, max(0, tint.y + grain.y)),
                min(1, max(0, tint.z + grain.z)), 1)
        }
        let row = boundary - distance * 4 / extent
        let wx = pow(abs(normalX), 6), wy = pow(abs(normalY), 6)
        let verticalWeight = wx / max(0.000001, wx + wy)
        var color = sample(x: y + 217, y: row) * verticalWeight
            + sample(x: x, y: row) * (1 - verticalWeight)
        guard color.w > 0.0001 else { return .zero }
        let straight = SIMD3(color.x, color.y, color.z) / color.w
        let luminance = straight.x * 0.2126 + straight.y * 0.7152 + straight.z * 0.0722
        // The asset's black/gray semitransparent pixels are the cast shadow;
        // pale partially covered pixels are fibres and retain their opacity.
        let isShadow = color.w < 0.98 && luminance < 0.65
        if isShadow {
            if !includeShadows { return .zero }
            let facing = max(0, -normalX * 0.55 - normalY * 0.83)
            color *= 0.20 + facing * 0.80
            if dark { color.x = color.w * 0.015; color.y = color.x; color.z = color.x }
        } else {
            let adjusted = tint + (straight - paperMean) * (dark ? 0.45 : 1)
            color.x = min(1, max(0, adjusted.x)) * color.w
            color.y = min(1, max(0, adjusted.y)) * color.w
            color.z = min(1, max(0, adjusted.z)) * color.w
        }
        let tail = min(1, max(0, (distance + 24 * extent) / (8 * extent)))
        return color * (tail * tail * (3 - 2 * tail))
    }

    private func sample(x: Double, y: Double) -> SIMD4<Double> {
        if y >= Double(height - 1) { return .zero }
        let sx = Self.mirror(x, length: width), sy = max(0, y)
        let ix = min(width - 2, Int(sx)), iy = min(height - 2, Int(sy))
        let fx = sx - Double(ix), fy = sy - Double(iy)
        func pixel(_ x: Int, _ y: Int) -> SIMD4<Double> {
            let i = (y * width + x) * 4
            return SIMD4(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]), Double(pixels[i + 3])) / 255
        }
        return (pixel(ix, iy) * (1 - fx) + pixel(ix + 1, iy) * fx) * (1 - fy)
            + (pixel(ix, iy + 1) * (1 - fx) + pixel(ix + 1, iy + 1) * fx) * fy
    }

    private static func mirror(_ value: Double, length: Int) -> Double {
        let end = Double(length - 1), period = end * 2
        var p = value.truncatingRemainder(dividingBy: period)
        if p < 0 { p += period }
        return p <= end ? p : period - p
    }
}

/// Decode once; neutral luminance modulates paper color without baking tears.
struct PaperMaterial {
    private let values: [Float]
    private let size = 768
    private let mean: Double

    init?(image: CGImage) {
        let resolution = 768
        var rgba = [UInt8](repeating: 0, count: resolution * resolution * 4)
        let decoded = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: resolution, height: resolution,
                bitsPerComponent: 8, bytesPerRow: resolution * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: resolution, height: resolution))
            return true
        }
        guard decoded else { return nil }
        var samples = [Float](repeating: 0, count: resolution * resolution), sum = 0.0
        for i in 0..<samples.count {
            let offset = i * 4
            let value = (Double(rgba[offset]) * 0.2126 + Double(rgba[offset + 1]) * 0.7152 + Double(rgba[offset + 2]) * 0.0722) / 255
            samples[i] = Float(value); sum += value
        }
        values = samples; mean = sum / Double(samples.count)
    }

    func sample(_ x: Double, _ y: Double) -> Double {
        let ix = Int(floor(x)), iy = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
        let a = mirrored(ix), b = mirrored(ix + 1), c = mirrored(iy), d = mirrored(iy + 1)
        let top = Double(values[c * size + a]) * (1 - fx) + Double(values[c * size + b]) * fx
        let bottom = Double(values[d * size + a]) * (1 - fx) + Double(values[d * size + b]) * fx
        return top * (1 - fy) + bottom * fy - mean
    }
    private func mirrored(_ n: Int) -> Int {
        let wrapped = (n % (size * 2) + size * 2) % (size * 2)
        return wrapped < size ? wrapped : size * 2 - wrapped - 1
    }
}
