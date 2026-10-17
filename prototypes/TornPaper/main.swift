import Foundation
import CoreGraphics
import ImageIO
import MapKit

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("output/materials/torn-paper-v1")
let texture = root.appendingPathComponent("Michi/Resources/Assets.xcassets/TornPaperSurface.imageset/paper-surface-v1.png")
let source = CGImageSourceCreateWithURL(texture as CFURL, nil)!
let material = PaperMaterial(image: CGImageSourceCreateImageAtIndex(source, 0, nil)!)!
let edgeURL = root.appendingPathComponent("Michi/Resources/Assets.xcassets/TornPaperFineEdge.imageset/thin-edge-v1.png")
let edgeSource = CGImageSourceCreateWithURL(edgeURL as CFURL, nil)!
let edgeMaterial = PaperEdgeMaterial(image: CGImageSourceCreateImageAtIndex(edgeSource, 0, nil)!)!
let zoom = 16
let center = MKMapPoint(CLLocationCoordinate2D(latitude: 35.70, longitude: 139.71))
let tileUnits = MKMapSize.world.width / pow(2, Double(zoom))
let baseX = Int(center.x / tileUnits) - 1, baseY = Int(center.y / tileUnits) - 1
func point(_ x: Double, _ y: Double) -> MKMapPoint {
    MKMapPoint(x: (Double(baseX) + x / 256) * tileUnits,
               y: (Double(baseY) + y / 256) * tileUnits)
}
let routes: [TornPaperRenderer.Segment] = [
    .init(start: point(-20, 150), end: point(180, 220)),
    .init(start: point(180, 220), end: point(300, 310)),
    .init(start: point(300, 310), end: point(540, 380))
]
let renderer = TornPaperRenderer(segments: routes, darkPaper: false, material: material, edgeMaterial: edgeMaterial)
let empty = TornPaperRenderer(segments: [], darkPaper: false, material: material, edgeMaterial: edgeMaterial)
precondition(renderer.contains(point(180, 220).coordinate))
precondition(!renderer.contains(point(50, 480).coordinate))
precondition(!empty.contains(point(180, 220).coordinate))
let expanded = TornPaperRenderer(segments: routes + [.init(start: point(300, 310), end: point(450, 80))],
    darkPaper: false, material: material, edgeMaterial: edgeMaterial)
precondition(!renderer.contains(point(450, 80).coordinate) && expanded.contains(point(450, 80).coordinate))

func bytes(_ image: CGImage) -> [UInt8] {
    let data = image.dataProvider!.data!
    return Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
}
func save(_ image: CGImage, _ name: String) {
    let target = output.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
}
let started = Date()
for scale in [0.3, 0.6, 1.0] {
    for lift in [0.0, 0.5, 1.0] {
        let relief = PaperEdgeRelief(lift: lift, scale: scale)
        let heights = (0...30).map { relief.elevation(at: Double($0) * scale) }
        precondition(heights[0] > 0 && heights[0] <= 6.81 * scale)
        precondition(zip(heights, heights.dropFirst()).allSatisfy { $0 >= $1 })
        precondition(heights.last == 0 && relief.slope(at: 30 * scale) == 0,
            "A shallow lift must join the flat sheet without detached tabs")
        for facing in [0.0, 0.5, 1.0] {
            let shadow = (0...30).map { relief.shadow(distance: Double($0) * scale, lightFacing: facing) }
            precondition(shadow.allSatisfy { $0 >= 0 && $0 <= 1 })
            precondition(zip(shadow, shadow.dropFirst()).allSatisfy { $0 >= $1 })
            precondition(shadow.last == 0, "No haze far inside the open map")
        }
    }
}
// Historical mesh helpers still compile for comparison; they are no longer
// invoked by the app renderer.
let boundary = (0...32).map { SIMD2(80.0 + Double($0) * 2, 100.0) }
let curved = PaperCurlPatch(boundary: boundary, normals: Array(repeating: SIMD2(0, -1), count: boundary.count),
    length: 24, angle: 2.25, seed: 0.3, textureOrigin: .zero)
let columns = curved.vertices.count / boundary.count
var turnedBack = false
for row in boundary.indices {
    let start = row * columns, end = start + columns - 1
    let rootVertex = curved.vertices[start]
    precondition(rootVertex.position.z == 0 && rootVertex.normal.z > 0.999,
        "The folded strip must meet the original sheet flat at its hinge")
    precondition(abs(rootVertex.uv.x - rootVertex.position.x * 3.2) < 0.001
        && abs(rootVertex.uv.y - rootVertex.position.y * 3.2) < 0.001,
        "Paper grain must connect continuously at the hinge")
    let firstUV = curved.vertices[start].uv, lastUV = curved.vertices[end].uv
    let unrolled = hypot(lastUV.x - firstUV.x, lastUV.y - firstUV.y) / 3.2
    var arc = 0.0
    for i in start..<end {
        let d = curved.vertices[i + 1].position - curved.vertices[i].position
        arc += sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
    }
    precondition(abs(arc - unrolled) < 0.01,
        "Bending must preserve the sheet's length rather than stretching an image")
    if curved.vertices[end].position.z > 5 && curved.vertices[end].normal.z < 0 { turnedBack = true }
}
precondition(turnedBack, "The free end must rise and turn over to expose the actual back face")
for lift in [0.0, 0.5, 1.0] {
    for facing in [0.0, 0.5, 1.0] {
        let profile = [0.0, 0.5, 1, 2, 4, 8, 16, 32, 64].map {
            TornPaperRenderer.edgeShadow(distance: $0, lift: lift, lightFacing: facing, scale: 1)
        }
        precondition(profile.allSatisfy { $0 >= 0 && $0 <= 1 })
        precondition(zip(profile, profile.dropFirst()).allSatisfy { $0 >= $1 }, "Shadow must fade away from underside")
        precondition(profile.last == 0, "No distant gray halo")
    }
}
precondition(TornPaperRenderer.edgeShadow(distance: 0, lift: 1, lightFacing: 1, scale: 1)
    > TornPaperRenderer.edgeShadow(distance: 0, lift: 0, lightFacing: 1, scale: 1))
let liftedContact = TornPaperRenderer.edgeShadow(distance: 0, lift: 1, lightFacing: 1, scale: 1)
let flatContact = TornPaperRenderer.edgeShadow(distance: 0, lift: 0, lightFacing: 1, scale: 1)
precondition(liftedContact > 0.72 && liftedContact - flatContact > 0.50,
    "Raised lips need a distinctly deeper shadow than flat paper")
precondition(TornPaperRenderer.edgeShadow(distance: 8, lift: 1, lightFacing: 1, scale: 1) > 0.12,
    "A lifted flap must cast a soft visible shadow beyond its contact line")
precondition(TornPaperRenderer.edgeShadow(distance: 8, lift: 0, lightFacing: 1, scale: 1) < 0.001,
    "Flat edges must not acquire a wide shadow halo")
var rendered: [CGImage] = []
for y in 0..<2 { for x in 0..<2 {
    let path = MKTileOverlayPath(x: baseX + x, y: baseY + y, z: zoom, contentScaleFactor: 3)
    let tile = renderer.render(at: path, screenPointsPerTileUnit: 1)!
    precondition(tile.width == 768 && tile.height == 768)
    rendered.append(tile)
}}
let firstPath = MKTileOverlayPath(x: baseX, y: baseY, z: zoom, contentScaleFactor: 3)
precondition(bytes(rendered[0]) == bytes(renderer.render(at: firstPath, screenPointsPerTileUnit: 1)!))
var indexed = renderer
indexed.segmentIndex = PaperSegmentIndex(segments: routes)
precondition(bytes(rendered[0]) == bytes(indexed.render(at: firstPath, screenPointsPerTileUnit: 1)!))
let distant = (0..<2000).map { i in
    TornPaperRenderer.Segment(start: point(10000 + Double(i) * 4, 10000),
        end: point(10004 + Double(i) * 4, 10020))
}
var largeHistory = TornPaperRenderer(segments: routes + distant, darkPaper: false,
    material: material, edgeMaterial: edgeMaterial)
largeHistory.segmentIndex = PaperSegmentIndex(segments: routes + distant)
precondition(bytes(rendered[0]) == bytes(largeHistory.render(at: firstPath, screenPointsPerTileUnit: 1)!))
let longSegment = [TornPaperRenderer.Segment(start: point(-5000, 128), end: point(5000, 128))]
let longPaper = TornPaperRenderer(segments: longSegment, darkPaper: false, material: material, edgeMaterial: edgeMaterial)
var indexedLongPaper = longPaper
indexedLongPaper.segmentIndex = PaperSegmentIndex(segments: longSegment + distant)
precondition(bytes(longPaper.render(at: firstPath, screenPointsPerTileUnit: 1)!)
    == bytes(indexedLongPaper.render(at: firstPath, screenPointsPerTileUnit: 1)!))
var cancellationChecks = 0
precondition(largeHistory.render(at: firstPath, screenPointsPerTileUnit: 1, isCancelled: {
    cancellationChecks += 1; return cancellationChecks > 2
}) == nil, "Canceled viewport work must stop during distance-field construction")
let previewPath = MKTileOverlayPath(x: baseX, y: baseY, z: zoom, contentScaleFactor: 0.5)
let preview = indexed.render(at: previewPath, screenPointsPerTileUnit: 1)!
precondition(preview.width == 128 && preview.height == 128, "Preview must be genuinely cheap, not full-resolution then resized")
if let option = CommandLine.arguments.firstIndex(of: "--reference"), option + 1 < CommandLine.arguments.count {
    let url = URL(fileURLWithPath: CommandLine.arguments[option + 1])
    let reference = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let referenceImage = CGImageSourceCreateImageAtIndex(reference, 0, nil)!
    let normalized = CGContext(data: nil, width: referenceImage.width, height: referenceImage.height,
        bitsPerComponent: 8, bytesPerRow: referenceImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    normalized.draw(referenceImage, in: CGRect(x: 0, y: 0, width: referenceImage.width, height: referenceImage.height))
    let old = bytes(normalized.makeImage()!), new = bytes(rendered[0])
    precondition(old.count == new.count)
    let difference = zip(old, new).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(old.count)
    print("Original/optimized mean channel difference: \(difference) / 255")
    precondition(difference < 0.1, "Fast paths must preserve the accepted paper appearance (allow PNG premultiplication rounding)")
}
precondition(renderer.render(at: firstPath, screenPointsPerTileUnit: 1, isCancelled: { true }) == nil)
let allPaper = bytes(empty.render(at: firstPath, screenPointsPerTileUnit: 1)!)
precondition(stride(from: 3, to: allPaper.count, by: 4).allSatisfy { allPaper[$0] == 255 })
let meanPaper = (0..<3).map { channel in
    stride(from: channel, to: allPaper.count, by: 4).reduce(0.0) { $0 + Double(allPaper[$1]) }
        / Double(allPaper.count / 4)
}
for (actual, expected) in zip(meanPaper, [205.0, 201.0, 194.0]) {
    precondition(abs(actual - expected) < 3, "Paper must retain the selected warm-gray color")
}
precondition(meanPaper[0] > meanPaper[1] && meanPaper[1] > meanPaper[2])
let tiles = rendered.map(bytes)
var opaque = 0, clear = 0, partial = 0
for tile in tiles { for i in stride(from: 3, to: tile.count, by: 4) {
    if tile[i] == 255 { opaque += 1 }
    else if tile[i] == 0 { clear += 1 }
    else { partial += 1 }
}}
precondition(opaque > 10000 && clear > 10000)
// The textured break includes wider soft shadows than the former thin rim.
// Check where transparency occurs, rather than a percentage that depends on
// route density and perimeter length within an arbitrarily selected tile.
for angle in 0..<16 {
    let radians = Double(angle) * .pi / 8
    for phase in stride(from: 0.0, to: 4096.0, by: 128) {
        for scale in [0.3, 0.6, 1.0] {
            let paper = edgeMaterial.edge(x: phase, y: phase * 1.618, distance: 32,
                normalX: cos(radians), normalY: sin(radians), scale: scale,
                tint: SIMD3(205.0 / 255, 201.0 / 255, 194.0 / 255), dark: false)
            let open = edgeMaterial.edge(x: phase, y: phase * 1.618, distance: -48,
                normalX: cos(radians), normalY: sin(radians), scale: scale,
                tint: SIMD3(205.0 / 255, 201.0 / 255, 194.0 / 255), dark: false)
            precondition(abs(paper.w - 1) < 0.000001, "Paper beyond the edge must remain fully opaque")
            precondition(open.w == 0, "No shadow or paper may extend into the open map beyond the edge band")
        }
    }
}
var colorDifference = 0.0, alphaDifference = 0.0, comparisons = 0
for row in 0..<2 {
    let left = tiles[row * 2], right = tiles[row * 2 + 1]
    for y in 0..<768 {
        let a = (y * 768 + 767) * 4, b = y * 768 * 4
        alphaDifference += abs(Double(left[a + 3]) - Double(right[b + 3])) / 255
        for channel in 0..<3 { colorDifference += abs(Double(left[a + channel]) - Double(right[b + channel])) / 255 }
        comparisons += 1
    }
}
precondition(alphaDifference / Double(comparisons) < 0.025)
precondition(colorDifference / Double(comparisons * 3) < 0.025)
for z in [15, 16, 17, 18] {
    let units = MKMapSize.world.width / (256 * pow(2, Double(z)))
    let p = point(180, 220)
    let tx = Int(floor(p.x / units / 256)), ty = Int(floor(p.y / units / 256))
    let path = MKTileOverlayPath(x: tx, y: ty, z: z, contentScaleFactor: 2)
    let image = renderer.render(at: path, screenPointsPerTileUnit: 1)!
    let ix = min(511, Int((p.x / units - Double(tx) * 256) * 2))
    let iy = min(511, Int((p.y / units - Double(ty) * 256) * 2))
    precondition(bytes(image)[(iy * 512 + ix) * 4 + 3] == 0, "Route must stay open at every zoom")
}
let changed = expanded.render(at: firstPath, screenPointsPerTileUnit: 1)!
let changedPath = MKTileOverlayPath(x: baseX + 1, y: baseY, z: zoom, contentScaleFactor: 3)
precondition(bytes(expanded.render(at: changedPath, screenPointsPerTileUnit: 1)!) != tiles[1], "Adding a route must change the opening")
let dark = TornPaperRenderer(segments: routes, darkPaper: true, material: material, edgeMaterial: edgeMaterial)
let darkBytes = bytes(dark.render(at: firstPath, screenPointsPerTileUnit: 1)!)
precondition(stride(from: 3, to: darkBytes.count, by: 4).allSatisfy { darkBytes[$0] == tiles[0][$0] })
for tile in tiles {
    for i in stride(from: 0, to: tile.count, by: 4) {
        precondition(tile[i] <= tile[i + 3] && tile[i + 1] <= tile[i + 3] && tile[i + 2] <= tile[i + 3],
            "Texture blending must preserve premultiplied alpha")
    }
}
save(rendered[0], "test-tile.png")
save(changed, "test-route-update.png")
print("PASS: bounded shallow edge relief, connected flat sheet, shadow falloff, warm-gray color, route/far/empty hit testing, added routes, deterministic render, cancellation, opaque paper, tile seams, 4 zoom levels, theme-independent mask; archived mesh helper regressions")
print("Alpha partial \(Double(partial) * 100 / Double(opaque + clear + partial))%; shared-edge mean RGB \(colorDifference / Double(comparisons * 3))")
print("Test render time \(String(format: "%.2f", Date().timeIntervalSince(started)))s")

// The actual app scheduler: preview first, final image second, repeat requests
// coalesced, obsolete pans/zooms canceled, and only the new viewport refined.
let pipeline = PaperTilePipeline(paper: indexed, scale: 3)
let testRect = MKMapRect(x: Double(baseX) * tileUnits + 20, y: Double(baseY) * tileUnits + 20,
    width: 180 / 256 * tileUnits, height: 180 / 256 * tileUnits)
let requested = PaperTileKey.covering(testRect, level: zoom)
let callbackLock = NSLock()
var observedSizes: [PaperTileKey: [Int]] = [:]
pipeline.setCallback { rect in
    let key = PaperTileKey(x: Int((rect.minX / tileUnits).rounded()), y: Int((rect.minY / tileUnits).rounded()), z: zoom)
    guard requested.contains(key), abs(rect.width - tileUnits) < 0.001,
          let image = pipeline.image(for: key) else { return }
    callbackLock.lock(); observedSizes[key, default: []].append(image.width); callbackLock.unlock()
}
for _ in 0..<30 { pipeline.updateViewport(testRect, zoomScale: 256 / tileUnits) }
let deadline = Date().addingTimeInterval(10)
while requested.contains(where: { pipeline.image(for: $0)?.width != 512 }), Date() < deadline {
    Thread.sleep(forTimeInterval: 0.005)
}
precondition(requested.allSatisfy { pipeline.image(for: $0)?.width == 512 })
callbackLock.lock()
for key in requested {
    let widths = observedSizes[key] ?? []
    precondition(widths.first == 128 && widths.last == 512 && widths.count == 2,
        "Repeated requests must share a single preview/final job")
}
callbackLock.unlock()
for step in 1...10 {
    let moving = MKMapRect(x: testRect.minX + Double(step) * tileUnits, y: testRect.minY,
        width: testRect.width, height: testRect.height)
    pipeline.updateViewport(moving, zoomScale: 512 / tileUnits)
}
pipeline.updateViewport(testRect, zoomScale: 256 / tileUnits)
pipeline.invalidate()
precondition(requested.allSatisfy { pipeline.image(for: $0) == nil })
pipeline.updateViewport(testRect, zoomScale: 256 / tileUnits)
Thread.sleep(forTimeInterval: 0.05)
precondition(requested.allSatisfy { pipeline.image(for: $0) == nil }, "Invalidated work must not refill the cache")
print("PASS: indexed distant/long routes, 128px preview → 512px final, request coalescing, rapid pan/zoom cancellation, invalidation")
