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
        // Meshes and their projected shadows may cross tile boundaries. Sample
        // the same world-aligned distance grid beyond each tile on all sides.
        let step = 2.0
        let padding = ceil(128 / screenScale / step) * step
        let gridSize = Int((256 + padding * 2) / step) + 1
        var field = [Double](repeating: searchRadius, count: gridSize * gridSize)
        for segment in segments {
            let ax = segment.start.x / mapUnitsPerPixel - originX + padding
            let ay = segment.start.y / mapUnitsPerPixel - originY + padding
            let bx = segment.end.x / mapUnitsPerPixel - originX + padding
            let by = segment.end.y / mapUnitsPerPixel - originY + padding
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
        for y in 0..<gridSize {
            let worldY = originY - padding + Double(y) * step
            let rowLatitude = MKMapPoint(x: (originX + 128) * mapUnitsPerPixel,
                y: worldY * mapUnitsPerPixel).coordinate.latitude
            let rowPixelsPerMeter = MKMapPointsPerMeterAtLatitude(rowLatitude) / mapUnitsPerPixel
            for x in 0..<gridSize {
                let nx = (originX - padding + Double(x) * step) * referenceFactor
                let ny = worldY * referenceFactor
                field[y * gridSize + x] -= (Self.revealRadiusMeters - Self.tearOffset(nx, ny)) * rowPixelsPerMeter
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
        let aa = scale / screenScale
        for y in 0..<size {
            if y.isMultiple(of: 32), isCancelled() { return nil }
            let py = (Double(y) + 0.5) / scale
            for x in 0..<size {
                let px = (Double(x) + 0.5) / scale
                let sample = distances.sample(x: px, y: py)
                let distance = sample.distance
                if distance < -8 * curlScale { continue }
                let nx = (originX + px) * referenceFactor
                let ny = (originY + py) * referenceFactor
                let sx = (originX + px) * screenScale, sy = (originY + py) * screenScale
                let grain = edgeMaterial?.surface(x: sx * 3.2, y: sy * 3.2)
                    ?? SIMD3(repeating: material?.sample(nx * 1.35, ny * 1.35) ?? 0)
                let face = paper + grain * (darkPaper ? 0.40 : 0.90)
                let fibreNoise = Self.noise(nx * 1.7 + ny * 0.31, ny * 1.9 - nx * 0.27)
                let tooth = Self.noise(nx * 0.43 + ny * 0.17, ny * 0.51 - nx * 0.21)
                let tear = distance + ((tooth - 0.5) * 2.5 + (fibreNoise - 0.5) * 0.8) * fibreResolution
                let coverage = Self.clamp(tear * aa + 0.5)
                let fringeWidth = (0.25 + fibreNoise * 0.8) * curlScale
                let fringe = Self.clamp((tear + fringeWidth) * aa + 0.5) * (0.55 + fibreNoise * 0.4)
                let fibreWeight = fringe * (1 - coverage)
                let lightFacing = max(0, -sample.normal.x * 0.55 - sample.normal.y * 0.83)
                let shadow = tear < 0 ? exp(-max(0, -tear - fringeWidth) / max(0.15, curlScale * 1.2))
                    * (0.12 + lightFacing * 0.16) : 0
                let shadowWeight = shadow * (1 - coverage) * (1 - fringe)
                let alpha = coverage + fibreWeight + shadowWeight
                let broken = exp(-max(0, tear) / max(0.15, fringeWidth)) * 0.25
                let i = (y * size + x) * 4
                for channel in 0..<3 {
                    let color = face[channel] * (1 - broken) + fibres[channel] * broken
                    pixels[i + channel] = UInt8((Self.clamp(color * coverage + fibres[channel] * fibreWeight
                        + (darkPaper ? 0.015 : 0.17) * shadowWeight) * 255).rounded())
                }
                pixels[i + 3] = UInt8((Self.clamp(alpha) * 255).rounded())
            }
        }
        let flaps = Self.makeFlaps(field: distances, originX: originX, originY: originY,
            referenceFactor: referenceFactor, screenScale: screenScale, curlScale: curlScale)
        guard !isCancelled() else { return nil }
        PaperCurlRasterizer(flaps: flaps, size: size, pixelsPerPoint: aa,
            paper: paper, dark: darkPaper, material: edgeMaterial)
            .render(into: &pixels)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

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
}

private struct PaperDistanceField {
    struct Sample { let distance: Double; let normal: SIMD2<Double> }
    let values: [Double]
    let side: Int
    let step: Double
    let padding: Double
    let screenScale: Double

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

/// Decodes the existing asset once. The app samples only its opaque surface
/// grain; folded edges and shadows are now generated by PaperCurlPatch and
/// PaperCurlRasterizer. The legacy ribbon sampler supports earlier studies.
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
