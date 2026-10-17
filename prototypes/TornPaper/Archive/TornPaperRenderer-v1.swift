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

    static let revealRadiusMeters = 115.0
    private static let referenceWorldPixels = 16_777_216.0
    let segments: [Segment]
    let darkPaper: Bool
    let material: PaperMaterial?

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
        let scale = min(3, max(1, Double(tile.contentScaleFactor)))
        let screenScale = min(2, max(0.5, screenPointsPerTileUnit))
        let size = Int(256 * scale)
        let worldPixels = 256 * pow(2, Double(tile.z))
        let originX = Double(tile.x) * 256, originY = Double(tile.y) * 256
        let mapUnitsPerPixel = MKMapSize.world.width / worldPixels
        let latitude = MKMapPoint(x: (originX + 128) * mapUnitsPerPixel,
            y: (originY + 128) * mapUnitsPerPixel).coordinate.latitude
        let pixelsPerMeter = MKMapPointsPerMeterAtLatitude(latitude) / mapUnitsPerPixel
        let radius = Self.revealRadiusMeters * pixelsPerMeter
        let searchRadius = radius + 20 * pixelsPerMeter + 24 / screenScale
        let gridSize = 129, step = 2.0
        var field = [Double](repeating: searchRadius, count: gridSize * gridSize)
        for segment in segments {
            let ax = segment.start.x / mapUnitsPerPixel - originX
            let ay = segment.start.y / mapUnitsPerPixel - originY
            let bx = segment.end.x / mapUnitsPerPixel - originX
            let by = segment.end.y / mapUnitsPerPixel - originY
            let minX = max(0, Int(floor((min(ax, bx) - searchRadius) / step)))
            let maxX = min(gridSize - 1, Int(ceil((max(ax, bx) + searchRadius) / step)))
            let minY = max(0, Int(floor((min(ay, by) - searchRadius) / step)))
            let maxY = min(gridSize - 1, Int(ceil((max(ay, by) + searchRadius) / step)))
            guard minX <= maxX, minY <= maxY else { continue }
            for y in minY...maxY { for x in minX...maxX {
                let i = y * gridSize + x
                field[i] = min(field[i], Self.distance(Double(x) * step, Double(y) * step, ax, ay, bx, by))
            }}
        }
        let referenceFactor = Self.referenceWorldPixels / worldPixels
        for y in 0..<gridSize { for x in 0..<gridSize {
            let nx = (originX + Double(x) * step) * referenceFactor
            let ny = (originY + Double(y) * step) * referenceFactor
            field[y * gridSize + x] -= radius - Self.tearOffset(nx, ny) * pixelsPerMeter
        }}

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let paper = darkPaper ? [0.060, 0.079, 0.112] : [0.961, 0.949, 0.924]
        let fibres = darkPaper ? [0.17, 0.19, 0.22] : [0.996, 0.989, 0.970]
        // Fade subpixel fibres at city-wide zoom rather than letting them alias.
        let fibreResolution = min(1, screenScale / max(0.001, referenceFactor))
        let aa = scale / screenScale
        for y in 0..<size {
            if y.isMultiple(of: 32), isCancelled() { return nil }
            let py = (Double(y) + 0.5) / scale
            let gy = py / step, iy = min(gridSize - 2, Int(gy)), fy = gy - Double(iy)
            for x in 0..<size {
                let px = (Double(x) + 0.5) / scale
                let gx = px / step, ix = min(gridSize - 2, Int(gx)), fx = gx - Double(ix)
                let a = iy * gridSize + ix, b = a + 1, c = a + gridSize, d = c + 1
                // Bilinear distances keep the mask continuous between tiles;
                // fine fibres are evaluated per output pixel, not on this grid.
                let top = field[a] + (field[b] - field[a]) * fx
                let bottom = field[c] + (field[d] - field[c]) * fx
                let distance = (top + (bottom - top) * fy) * screenScale
                let dx = ((field[b] - field[a]) * (1 - fy) + (field[d] - field[c]) * fy) / step
                let dy = (bottom - top) / step
                let magnitude = max(0.0001, hypot(dx, dy))
                let nx = (originX + px) * referenceFactor
                let ny = (originY + py) * referenceFactor

                var tear = distance
                var fringe = 0.0
                var lift = 0.0
                var light = 0.0
                var rimTexture = 0.0
                if abs(distance) < 20 {
                    let fibreNoise = Self.noise(nx * 1.7 + ny * 0.31, ny * 1.9 - nx * 0.27)
                    let shortFibres = Self.noise(nx * 4.6 - ny * 1.3, ny * 3.1 + nx * 1.5)
                    tear += (fibreNoise - 0.5) * 1.4 * fibreResolution
                    let fringeWidth = (0.65 + fibreNoise * 1.25) * min(1, radius * screenScale / 12)
                    let fibreCoverage = Self.clamp((tear + fringeWidth) * aa + 0.5)
                    fringe = fibreCoverage * (0.68 + shortFibres * 0.28)
                    lift = Self.noise(nx * 0.065 + 23, ny * 0.071 - 41)
                    light = (-dx * 0.55 - dy * 0.83) / magnitude
                    rimTexture = (shortFibres - 0.5) * 0.025 * fibreResolution
                }
                let coverage = Self.clamp(tear * aa + 0.5)
                let fibreWeight = fringe * (1 - coverage)
                // Thin raised paper, not a stone cross-section. Its only depth
                // cues are a tiny rolled lip and a soft, directional shadow.
                let shadowReach = 1.8 + max(0, light) * (3.5 + lift * 3.0)
                let shadowDistance = max(0, -tear)
                let shadow = tear < 0 && shadowDistance < shadowReach * 2.2
                    ? exp(-pow(shadowDistance / shadowReach, 1.45)) * (0.13 + max(0, light) * 0.13)
                    : 0
                let shadowWeight = shadow * (1 - coverage) * (1 - fringe)
                let alpha = coverage + fibreWeight + shadowWeight
                guard alpha > 0.001 else { continue }
                let detail = (material?.sample(nx * 1.35, ny * 1.35) ?? 0) * (darkPaper ? 0.22 : 0.38)
                let lip = max(0, 1 - abs(tear - 0.75) / 1.8) * (0.012 + max(0, light) * 0.021)
                let curl = max(0, 1 - abs(tear - 3.2) / 4.5) * lift * 0.018
                let i = (y * size + x) * 4
                for channel in 0..<3 {
                    let face = Self.clamp(paper[channel] + detail + lip - curl)
                    let fibre = Self.clamp(fibres[channel] + rimTexture)
                    let shade = darkPaper ? 0.015 : 0.23
                    pixels[i + channel] = UInt8(Self.clamp(face * coverage + fibre * fibreWeight + shade * shadowWeight) * 255)
                }
                pixels[i + 3] = UInt8(Self.clamp(alpha) * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
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
