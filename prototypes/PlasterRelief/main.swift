import AppKit
import MapKit
import ImageIO

// Standalone material study. Does not change the app or its UI.
// Color, height, normals, ambient occlusion, and cast shadows are separate.
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("output/materials/relief-study-v3", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let width = 960, height = 1200

func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, x)) }
func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func smooth(_ x: Double) -> Double { let t = clamp(x); return t * t * (3 - 2 * t) }
func linear(_ values: [Double], _ u: Double) -> Double {
    let p = clamp((u + 1) * 0.5) * Double(values.count - 1)
    let i = min(values.count - 2, Int(p))
    return mix(values[i], values[i + 1], p - Double(i))
}

struct Bitmap {
    let width: Int, height: Int
    var pixels: [UInt8]
    init(_ image: CGImage) {
        width = image.width; height = image.height
        pixels = []
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes {
            let ctx = CGContext(data: $0.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        pixels = data
    }
    func sample(_ x: Double, _ y: Double, _ channel: Int) -> Double {
        func mirrored(_ n: Int, _ length: Int) -> Int {
            let p = (n % (length * 2) + length * 2) % (length * 2)
            return p < length ? p : length * 2 - p - 1
        }
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - floor(x), fy = y - floor(y)
        func value(_ a: Int, _ b: Int) -> Double {
            Double(pixels[(mirrored(b, height) * width + mirrored(a, width)) * 4 + channel]) / 255
        }
        return mix(mix(value(x0, y0), value(x0 + 1, y0), fx),
                   mix(value(x0, y0 + 1), value(x0 + 1, y0 + 1), fx), fy)
    }
}

func load(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
func save(_ pixels: [UInt8], _ w: Int, _ h: Int, _ name: String) throws {
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
    try png.write(to: output.appendingPathComponent(name))
}

// Three reusable height stamps. White = intact slab, black = exposed map.
// Macro fractures are deliberately sparse: broad planar bites, not fractal teeth.
struct FractureStamp {
    let top: [Double]
    let middleWidth: [Double]
    let bottomWidth: [Double]
    let slope: [Double]
    let fragmentU: Double
    func height(_ u: Double, _ v: Double) -> Double {
        let edge = linear(top, u)
        let m = max(0, linear(middleWidth, u))
        let b = max(0, linear(bottomWidth, u))
        let bevel = linear(slope, u)
        let lowerH = 2.4 + linear([0, 1.0, -0.4, 0.8, 0], u)
        let middleH = 7.1 + linear([0, -0.7, 0.6, -0.3, 0], u)
        func face(_ d: Double, _ span: Double) -> Double {
            // Predominantly planar wall, with only a small rounding at its lips.
            let t = clamp(d / span)
            return mix(t, smooth(t), 0.22)
        }
        let low = lowerH * face(v - (edge - m - b), bevel * 0.70)
        let mid = (middleH - lowerH) * face(v - (edge - m), bevel)
        let upper = (13.0 - middleH) * face(v - edge, bevel * 0.82)
        // One small, angular remnant, next to a large break. Never a repeating
        // fine-toothed border or a continuous ledge around the whole opening.
        let fragmentV = linear(top, fragmentU) - linear(middleWidth, fragmentU)
            - linear(bottomWidth, fragmentU) - 0.032
        let chip = abs((u - fragmentU) / 0.024) + abs((v - fragmentV) / 0.026)
        let remnant = clamp((1 - chip) * 8) * 2.7
        return max(low + mid + upper, remnant)
    }
}
let stamps = [
    FractureStamp(
        top: [0, 0.04, 0.43, 0.38, -0.08, 0],
        middleWidth: [0, 0, 0.008, 0.060, 0.006, 0],
        bottomWidth: [0, 0, 0.025, 0.038, 0, 0],
        slope: [0.010, 0.009, 0.015, 0.010, 0.007, 0.010], fragmentU: 0.30),
    FractureStamp(
        top: [0, -0.26, -0.21, 0.26, 0],
        middleWidth: [0, 0.058, 0.012, 0, 0],
        bottomWidth: [0, 0.003, 0.035, 0, 0],
        slope: [0.010, 0.012, 0.009, 0.014, 0.010], fragmentU: -0.42),
    FractureStamp(
        top: [0, 0.28, 0.35, -0.30, -0.26, 0],
        middleWidth: [0, 0, 0.052, 0.025, 0, 0],
        bottomWidth: [0, 0.026, 0.035, 0, 0, 0],
        slope: [0.010, 0.008, 0.014, 0.011, 0.008, 0.010], fragmentU: -0.08)
]
// Preserve narrow, near-vertical fractures in the height assets themselves.
let stampSize = 768
var stampImages: [[Double]] = []
for (index, stamp) in stamps.enumerated() {
    var floats = [Double](repeating: 0, count: stampSize * stampSize)
    var bytes = [UInt8](repeating: 255, count: stampSize * stampSize * 4)
    for y in 0..<stampSize { for x in 0..<stampSize {
        let u = Double(x) / Double(stampSize - 1) * 2 - 1
        let v = 1 - Double(y) / Double(stampSize - 1) * 2
        let h = stamp.height(u, v)
        floats[y * stampSize + x] = h
        let gray = UInt8(clamp(h / 13) * 255)
        for c in 0..<3 { bytes[(y * stampSize + x) * 4 + c] = gray }
    }}
    stampImages.append(floats)
    try save(bytes, stampSize, stampSize, "fracture-height-\(index + 1).png")
}
func sampleStamp(_ index: Int, _ u: Double, _ v: Double) -> Double {
    if v >= 1 { return 13 }; if v <= -1 { return 0 }
    let x = clamp((u + 1) * 0.5) * Double(stampSize - 1)
    let y = clamp((1 - v) * 0.5) * Double(stampSize - 1)
    let ix = min(stampSize - 2, Int(x)), iy = min(stampSize - 2, Int(y))
    let fx = x - Double(ix), fy = y - Double(iy)
    let a = stampImages[index]
    return mix(mix(a[iy * stampSize + ix], a[iy * stampSize + ix + 1], fx),
        mix(a[(iy + 1) * stampSize + ix], a[(iy + 1) * stampSize + ix + 1], fx), fy)
}

let mapURL = output.appendingPathComponent("map-background.png")
let cachedMap = root.appendingPathComponent("output/materials/relief-study-v1/map-background.png")
if !FileManager.default.fileExists(atPath: mapURL.path), FileManager.default.fileExists(atPath: cachedMap.path) {
    try FileManager.default.copyItem(at: cachedMap, to: mapURL)
}
if !FileManager.default.fileExists(atPath: mapURL.path) {
    let options = MKMapSnapshotter.Options()
    options.size = CGSize(width: width, height: height)
    options.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 35.7085, longitude: 139.719),
        latitudinalMeters: 1600, longitudinalMeters: 1280)
    options.mapType = .standard
    options.pointOfInterestFilter = .excludingAll
    options.appearance = NSAppearance(named: .aqua)
    let snapshotter = MKMapSnapshotter(options: options)
    var done = false, failure: Error?
    snapshotter.start(with: .main) { snapshot, error in
        defer { done = true }
        guard let snapshot, let tiff = snapshot.image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:])
        else { failure = error; return }
        do { try png.write(to: mapURL) } catch { failure = error }
    }
    let deadline = Date().addingTimeInterval(50)
    while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    guard done, failure == nil else { fatalError("Map snapshot: \(String(describing: failure))") }
}
guard let mapImage = load(mapURL), let plasterImage = load(root.appendingPathComponent("output/materials/plaster-surface-v1.png"))
else { fatalError("Missing material or map") }
let map = Bitmap(mapImage), plaster = Bitmap(plasterImage)

struct Point { let x: Double, y: Double }
let path = [Point(x: -210, y: 50), Point(x: 180, y: 330), Point(x: 530, y: 570),
            Point(x: 490, y: 850), Point(x: 1020, y: 1210)]
var lengths: [Double] = [0]
for i in 1..<path.count {
    lengths.append(lengths.last! + hypot(path[i].x - path[i - 1].x, path[i].y - path[i - 1].y))
}
let started = Date()
// Fractures span several hundred pixels, with unequal spacing. No regular
// sawtooth repetition. The two banks use independently staggered stamp runs.
let stations = [-800.0, 0, 690, 1580, 2180, 3160, 3900]
// Local, broad fracture events. Each bite is a handful of planar faces;
// there is deliberately no octave/fractal noise along the silhouette.
struct Bite { let center: Double, halfWidth: Double, depth: Double }
let bites = [
    Bite(center: 150, halfWidth: 44, depth: -15),
    Bite(center: 345, halfWidth: 57, depth: 11),
    Bite(center: 526, halfWidth: 33, depth: -22),
    Bite(center: 735, halfWidth: 65, depth: -19),
    Bite(center: 952, halfWidth: 41, depth: 14),
    Bite(center: 1115, halfWidth: 56, depth: -26),
    Bite(center: 1338, halfWidth: 38, depth: -18),
    Bite(center: 1542, halfWidth: 70, depth: 12),
    Bite(center: 1775, halfWidth: 46, depth: -23),
    Bite(center: 1980, halfWidth: 53, depth: -14),
    Bite(center: 2240, halfWidth: 39, depth: 12)
]
func localFracture(_ arc: Double) -> Double {
    var displacement = 0.0
    for bite in bites {
        let t = (arc - bite.center) / bite.halfWidth
        guard abs(t) < 1 else { continue }
        let shape: Double
        if t < -0.30 { shape = (t + 1) / 0.70 }
        else if t < 0.27 { shape = 1 - (t + 0.30) * 0.15 }
        else { shape = (1 - t) / 0.73 * 0.9145 }
        displacement += shape * bite.depth
    }
    return displacement
}
var heights = [Double](repeating: 0, count: width * height)
for y in 0..<height { for x in 0..<width {
    var nearest = Double.infinity, arc = 0.0, side = 1.0
    for i in 1..<path.count {
        let a = path[i - 1], b = path[i]
        let dx = b.x - a.x, dy = b.y - a.y, len = lengths[i] - lengths[i - 1]
        let t = clamp(((Double(x) - a.x) * dx + (Double(y) - a.y) * dy) / (len * len))
        let px = Double(x) - a.x - dx * t, py = Double(y) - a.y - dy * t
        let distance = hypot(px, py)
        if distance < nearest {
            nearest = distance; arc = lengths[i - 1] + len * t
            side = dx * py - dy * px >= 0 ? 1 : -1
        }
    }
    let phase = arc + (side > 0 ? 313 : 0)
    let index = (0..<stations.count - 1).first(where: { phase < stations[$0 + 1] }) ?? stations.count - 2
    let u = (phase - stations[index]) / (stations[index + 1] - stations[index]) * 2 - 1
    let v = (nearest - 181 + localFracture(phase)) / 155
    let material = sampleStamp((index + (side > 0 ? 1 : 0)) % stamps.count, u, v)
    // The color texture contributes only shallow micro relief, never macro shape.
    let grain = plaster.sample(Double(x) * 0.92, Double(y) * 0.92, 0) - 0.88
    heights[y * width + x] = max(0, material + grain * 0.20 * smooth(material / 2))
}}
precondition(heights.allSatisfy { $0.isFinite && $0 >= 0 && $0 < 14 })
let revealedCount = heights.filter { $0 < 0.05 }.count
precondition(revealedCount > width * height / 5 && revealedCount < width * height * 4 / 5)
func h(_ x: Double, _ y: Double) -> Double {
    let cx = clamp(x, 0, Double(width - 1)), cy = clamp(y, 0, Double(height - 1))
    let ix = min(width - 2, Int(cx)), iy = min(height - 2, Int(cy))
    return mix(mix(heights[iy * width + ix], heights[iy * width + ix + 1], cx - Double(ix)),
        mix(heights[(iy + 1) * width + ix], heights[(iy + 1) * width + ix + 1], cx - Double(ix)), cy - Double(iy))
}
var pixels = [UInt8](repeating: 255, count: width * height * 4)
var clay = pixels, heightBytes = pixels
let lx = -0.45, ly = -0.55, lz = 0.704
for y in 0..<height { for x in 0..<width {
    let screenX = Double(x), screenY = Double(y)
    let px = screenX
    var py = screenY, value = 0.0
    // Slightly oblique orthographic viewing rays expose steep sidewalls.
    // Unlike a broad bevel, this does not enlarge the actual fracture width.
    let viewSlope = 0.42
    var previousZ = 13.5
    for z in stride(from: 13.5, through: 0.0, by: -0.30) {
        if h(px, screenY + z * viewSlope) >= z {
            var low = z, high = previousZ
            for _ in 0..<5 {
                let middle = (low + high) * 0.5
                if h(px, screenY + middle * viewSlope) >= middle { low = middle }
                else { high = middle }
            }
            value = low; py = screenY + value * viewSlope
            break
        }
        previousZ = z
    }
    let dx = (h(px + 0.75, py) - h(px - 0.75, py)) / 1.5
    let dy = (h(px, py + 0.75) - h(px, py - 0.75)) / 1.5
    let norm = sqrt(dx * dx + dy * dy + 1)
    let diffuse = max(0, (-dx * lx - dy * ly + lz) / norm)
    var shadow = 0.0
    // Three nearby light directions give a narrow soft penumbra. All shadows
    // are derived from the heightfield, not painted along a contour.
    for jitter in [-0.10, 0.0, 0.10] {
        for distance in stride(from: 1.5, through: 31.5, by: 1.5) {
            let sample = h(px + distance * (lx + jitter), py + distance * (ly - jitter))
            if sample > value + distance * lz + 0.30 { shadow += 1.0 / 3.0; break }
        }
    }
    var occlusion = 0.0
    for (ox, oy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
        for radius in [2.0, 6.0, 13.0] {
            occlusion += clamp((h(px + ox * radius, py + oy * radius) - value) / (radius * 1.7)) / 12
        }
    }
    let exposed = value < 0.05
    let illumination = exposed ? 1 - shadow * 0.24 - occlusion * 0.10
        : clamp((0.70 + 0.30 * diffuse / lz) * (1 - shadow * 0.20) * (1 - occlusion * 0.20), 0.56, 1.06)
    let index = (y * width + x) * 4
    let luminance = plaster.sample(px * 0.92, py * 0.92, 0) * 0.2126
        + plaster.sample(px * 0.92, py * 0.92, 1) * 0.7152 + plaster.sample(px * 0.92, py * 0.92, 2) * 0.0722
    let detail = (luminance - 0.88) * 0.25
    for c in 0..<3 {
        let base: Double
        if exposed { base = map.sample(px * Double(map.width) / Double(width), py * Double(map.height) / Double(height), c) }
        else { base = [0.957, 0.946, 0.921][c] + detail }
        pixels[index + c] = UInt8(clamp(base * illumination) * 255)
        clay[index + c] = UInt8(clamp((exposed ? 0.77 : 0.94) * illumination) * 255)
        heightBytes[index + c] = UInt8(clamp(value / 13.1) * 255)
    }
    // Keep Apple's original attribution pixels unobstructed in the study.
    if y > height - 25 && x < 230 {
        for c in 0..<3 { pixels[index + c] = UInt8(clamp(map.sample(px * Double(map.width) / Double(width), py * Double(map.height) / Double(height), c)) * 255) }
    }
}}
try save(pixels, width, height, "relief-map-preview.png")
try save(clay, width, height, "relief-clay-preview.png")
try save(heightBytes, width, height, "relief-heightfield.png")
// Exact 1:1 detail, not an AI mockup or an enlarged/resampled screenshot.
let detailX = 180, detailY = 220, detailWidth = 620, detailHeight = 720
var detail = [UInt8](repeating: 0, count: detailWidth * detailHeight * 4)
for y in 0..<detailHeight { for x in 0..<detailWidth {
    for c in 0..<4 { detail[(y * detailWidth + x) * 4 + c] = pixels[((y + detailY) * width + x + detailX) * 4 + c] }
}}
try save(detail, detailWidth, detailHeight, "relief-detail.png")
print("Rendered \(width)×\(height) real heightfield with three reusable height stamps in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
print("Height/coverage assertions passed; exposed pixels: \(revealedCount)")
print(output.path)
