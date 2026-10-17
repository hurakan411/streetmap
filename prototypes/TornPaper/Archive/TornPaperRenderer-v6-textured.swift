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
    var edgeMaterial: PaperEdgeMaterial? = nil

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
        let searchRadius = radius + 20 * pixelsPerMeter + 64 / screenScale
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
        // Warm gray (#CDC9C2): a quiet sheet, visibly distinct from the light
        // map. Keep the existing dark-template palette for UI contrast.
        let paper = darkPaper ? [0.060, 0.079, 0.112] : [205.0 / 255, 201.0 / 255, 194.0 / 255]
        let fibres = darkPaper ? [0.17, 0.19, 0.22] : [0.996, 0.989, 0.970]
        // Fade subpixel fibres at city-wide zoom rather than letting them alias.
        let fibreResolution = min(1, screenScale / max(0.001, referenceFactor))
        let curlScale = min(1, radius * screenScale / 30)
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

                if let edgeMaterial {
                    let sx = (originX + px) * screenScale
                    let sy = (originY + py) * screenScale
                    let grain = edgeMaterial.surface(x: sx * 3.2, y: sy * 3.2)
                    let contrast = darkPaper ? 0.40 : 0.90
                    var rgba = SIMD4<Double>(
                        Self.clamp(paper[0] + grain.x * contrast),
                        Self.clamp(paper[1] + grain.y * contrast),
                        Self.clamp(paper[2] + grain.z * contrast), 1)
                    if distance < 32 {
                        if distance < -48 {
                            continue
                        }
                        let edge = edgeMaterial.edge(x: sx * 4, y: sy * 4,
                            distance: distance, normalX: dx / magnitude, normalY: dy / magnitude,
                            scale: curlScale, tint: SIMD3(paper[0], paper[1], paper[2]), dark: darkPaper)
                        let blend = 1 - Self.smoothstep(15 * curlScale, 28 * curlScale, distance)
                        rgba = rgba * (1 - blend) + edge * blend
                    }
                    let i = (y * size + x) * 4
                    for channel in 0..<4 {
                        // Bilinear interpolation of opaque texels can produce
                        // 0.999999999. Round rather than turning that into a
                        // translucent 254/255 seam over the underlying map.
                        pixels[i + channel] = UInt8((Self.clamp(rgba[channel]) * 255).rounded())
                    }
                    continue
                }

                var tear = distance
                var lift = 0.0, light = 0.0, flap = 0.0
                var fibreNoise = 0.5, shortFibres = 0.5
                var rollWidth = 0.0
                if abs(distance) < 64 {
                    fibreNoise = Self.noise(nx * 1.7 + ny * 0.31, ny * 1.9 - nx * 0.27)
                    shortFibres = Self.noise(nx * 4.6 - ny * 1.3, ny * 3.1 + nx * 1.5)
                    let tooth = Self.noise(nx * 0.43 + ny * 0.17, ny * 0.51 - nx * 0.21)
                    tear += ((tooth - 0.5) * 3.4 + (fibreNoise - 0.5) * 1.1) * fibreResolution

                    // Sample along the projected cut edge, not across the
                    // width of the fold. Otherwise the back reads as a wavy
                    // white tube rather than a single piece of folded paper.
                    let bx = nx - distance / screenScale * dx / magnitude * referenceFactor
                    let by = ny - distance / screenScale * dy / magnitude * referenceFactor
                    let raised = Self.noise(bx * 0.013 + by * 0.004 + 23, by * 0.016 - bx * 0.005 - 41)
                    lift = 0.18 + Self.clamp((raised - 0.15) / 0.70) * 0.70
                    let folded = Self.noise(bx * 0.022 - by * 0.006 + 83, by * 0.025 + bx * 0.007 + 19)
                    flap = Self.smoothstep(0.59, 0.79, folded)
                    rollWidth = (5.0 + raised * 7.0) * flap * curlScale
                    // The torn end turns BACK onto the opaque sheet. Most of
                    // the perimeter has only thin fibres; the white back is
                    // visible at these isolated folds, not around the hole.
                    tear -= flap * 2.4 * curlScale
                    light = (-dx * 0.55 - dy * 0.83) / magnitude
                }
                let coverage = Self.clamp(tear * aa + 0.5)
                let fringeWidth = (0.25 + fibreNoise * 0.65) * curlScale
                let fringe = Self.clamp((tear + fringeWidth) * aa + 0.5) * (0.45 + shortFibres * 0.5)
                let fibreWeight = fringe * (1 - coverage)
                let shadowDistance = max(0, -tear - fringeWidth)
                let lightFacing = max(0, light)
                let shadow = tear < 0 ? Self.edgeShadow(distance: shadowDistance,
                    lift: min(1, lift + flap * 0.25), lightFacing: lightFacing, scale: curlScale) : 0
                let shadowWeight = shadow * (1 - coverage) * (1 - fringe)
                let alpha = coverage + fibreWeight + shadowWeight
                guard alpha > 0.001 else { continue }
                let detail = (material?.sample(nx * 1.35, ny * 1.35) ?? 0) * (darkPaper ? 0.45 : 1.10)

                let curlWidth = (2.5 + lift * 8) * curlScale
                let shoulder = pow(1 - Self.clamp(max(0, tear) / max(0.1, curlWidth)), 2)
                let faceLighting = 1 + shoulder * lift * (lightFacing * 0.06 - max(0, -light) * 0.045)
                // A thin delaminated, fibrous break; its width varies at a
                // much smaller scale than the occasional folded-back flap.
                let tornWidth = (0.35 + fibreNoise * 0.80) * curlScale
                let exposedFibre = exp(-max(0, tear) / max(0.15, tornWidth)) * (0.30 + shortFibres * 0.45)
                let backPosition = Self.clamp(max(0, tear) / max(0.1, rollWidth))
                let backWeight = Self.smoothstep(0.3, 1.3, rollWidth)
                    * (1 - Self.smoothstep(rollWidth - 0.3, rollWidth + 0.3, tear))
                // The rolled-back end overlaps the sheet and casts a separate
                // shadow onto it. This is what gives a flap a readable tip.
                let onSheetDistance = max(0, tear - rollWidth)
                let onSheetShadow = tear > rollWidth && rollWidth > 0.3
                    ? flap * (0.17 + max(0, -light) * 0.20)
                        * exp(-onSheetDistance / max(0.3, (0.7 + flap * 2.5) * curlScale)) : 0
                let backShading = 0.12 * pow(1 - backPosition, 3)
                    + 0.06 * pow(backPosition, 5) - 0.025 * sin(backPosition * .pi)
                let i = (y * size + x) * 4
                for channel in 0..<3 {
                    let fibre = Self.clamp(fibres[channel] + (shortFibres - 0.5) * 0.04)
                    let topFace = Self.clamp((paper[channel] + detail) * faceLighting - onSheetShadow)
                    let brokenFace = topFace * (1 - exposedFibre) + fibre * exposedFibre
                    let underside = Self.clamp((darkPaper ? [0.11, 0.13, 0.16] : [0.970, 0.959, 0.939])[channel]
                        + detail * 0.45 - backShading * (darkPaper ? 0.4 : 1))
                    let face = brokenFace * (1 - backWeight) + underside * backWeight
                    let shade = darkPaper ? 0.015 : [0.21, 0.20, 0.18][channel]
                    pixels[i + channel] = UInt8(Self.clamp(face * coverage
                        + fibre * fibreWeight + shade * shadowWeight) * 255)
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
}

/// A real photographed-style break, white core, folded backs and transparent
/// shadow. The ribbon follows the route distance field; the image never defines
/// the revealed geography. Two continuous projections avoid a UV seam when a
/// contour turns from horizontal to vertical.
struct PaperEdgeMaterial {
    private let pixels: [UInt8]
    private let width: Int
    private let height: Int
    private let boundary: Double
    private let paperMean: SIMD3<Double>
    private let surfaceHeight: Int

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
        for x in stride(from: 0, to: width, by: 4) {
            for y in (height / 4)..<(height * 3 / 4) {
                if data[(y * width + x) * 4 + 3] < 230 {
                    sumY += Double(y); count += 1; break
                }
            }
        }
        guard count > 0 else { return nil }
        boundary = sumY / count
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

    func edge(x: Double, y: Double, distance: Double, normalX: Double, normalY: Double,
              scale: Double, tint: SIMD3<Double>, dark: Bool) -> SIMD4<Double> {
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
