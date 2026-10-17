import CoreGraphics
import Foundation
import ImageIO
import MapKit
import QuartzCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print("FAIL: \(message)"); fatalError(message) }
}

let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
let placement = MidnightHexPlacement.animation(center: CGPoint(x: 100, y: 200), radius: 24,
    restingHeight: 4, beginTime: 10)
require(placement.duration > 0.5 && placement.animations?.count == 3, "Placement must actually run in Core Animation")
for child in placement.animations ?? [] {
    require(child.duration == placement.duration, "A zero-duration child makes the tile jump instead of fall")
}
let fall = placement.animations!.first as! CAKeyframeAnimation
let values = fall.values!.map { ($0 as! NSNumber).doubleValue }
require(values.first! < 200 && values.last! == 200 && fall.keyPath == "position.y",
    "The actual layer animation must descend from above into its final position")
let grid = MidnightHexGrid()
let mapCenter = MKMapPoint(CLLocationCoordinate2D(latitude: 35.701, longitude: 139.702))
func unproject(_ p: CGPoint, scale: Double = 50, offset: Double = 0) -> MKMapPoint {
    MKMapPoint(x: mapCenter.x + (p.x - bounds.midX) * scale + offset,
        y: mapCenter.y + (p.y - bounds.midY) * scale)
}
func project(_ p: MKMapPoint, scale: Double = 50, offset: Double = 0) -> CGPoint {
    CGPoint(x: (p.x - mapCenter.x - offset) / scale + bounds.midX,
        y: (p.y - mapCenter.y) / scale + bounds.midY)
}
func update(_ surface: MidnightHexSurface, time: Double, scale: Double = 50, offset: Double = 0) {
    surface.updateViewport(bounds, time: time,
        unproject: { unproject($0, scale: scale, offset: offset) },
        project: { project($0, scale: scale, offset: offset) })
}
let a = unproject(.zero), b = unproject(CGPoint(x: bounds.maxX, y: bounds.maxY))
let ids = grid.cells(in: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
require(Set(ids).count == ids.count, "A map cell must appear only once")
for id in ids { require(grid.cell(at: grid.center(of: id)) == id, "World centers must round trip") }

let surface = MidnightHexSurface(segments: [])
update(surface, time: 100)
require(surface.tiles(time: 100).allSatisfy { surface.entryDelays[$0.id] == nil },
    "Visible entry tiles must begin before the first piece falls; overscan is already settled")
let airborne = surface.tiles(time: 100.35).filter { surface.entryDelays[$0.id] != nil }
require(airborne.count > 1 && airborne.allSatisfy { MidnightHexArtwork.fallOffset($0.fallProgress) < 0 },
    "Entry pieces must fall from above")
let entry = surface.entryDelays
require(!entry.isEmpty && entry.count < 800, "Only visible cells may be queued")
let delays = entry.values.sorted()
require(delays.last! + MidnightHexSurface.fallDuration <= 2, "Random groups must all land within two seconds")
require(zip(delays, delays.dropFirst()).filter { $1 - $0 < 0.015 }.count > delays.count / 3,
    "Several tiles must launch together instead of singly")
let firstCells = entry.filter { $0.value < 0.08 }.map { grid.center(of: $0.key) }
require(firstCells.count >= 5 && firstCells.map(\.y).max()! - firstCells.map(\.y).min()! > grid.radius * 3,
    "First group must be spatially scattered, not a scanline")
let settled = surface.tiles(time: 102)
require(settled.allSatisfy { $0.coverage == 1 && $0.fallProgress == nil }, "Entry must complete within two seconds")

// A routine camera/data refresh must not cancel the entry queue or restart time.
surface.update(segments: [])
update(surface, time: 100.3)
require(surface.entryDelays == entry, "A data refresh must preserve the initial placement queue")
let refreshed = surface.tiles(time: 100.35).filter { entry[$0.id] != nil }
require(refreshed.map(\.fallProgress) == airborne.map(\.fallProgress), "A refresh must preserve the running fall")

// World cells keep their identity and local geometry, but project to twice the
// screen size when zooming in by two. The old screen-fixed behavior is forbidden.
update(surface, time: 103, scale: 25)
let zoomed = surface.tiles(time: 103)
let old = Dictionary(uniqueKeysWithValues: settled.map { ($0.id, $0) })
let common = zoomed.filter { old[$0.id] != nil }
require(!common.isEmpty, "A zoom must retain overlapping geographic cells")
for tile in common {
    require(tile.center == old[tile.id]!.center, "A cell must retain its world identity during zoom")
}
require(grid.radius / 25 == (grid.radius / 50) * 2, "Tiles must scale naturally with the map")
require(surface.entryDelays == entry, "Zoom must not queue more placement animations")
update(surface, time: 103.2, scale: 50)
require(surface.tiles(time: 103.2).map(\.id) == settled.map(\.id), "Zooming back must restore the original geographic cells")

update(surface, time: 100.4, offset: 20_000)
let panned = surface.tiles(time: 100.4)
require(panned.filter { entry[$0.id] == nil }.allSatisfy { $0.fallProgress == nil },
    "Panned-in cells must appear immediately, never join the fall")
require(surface.entryDelays == entry, "Entry animation must stay limited to its original viewport")
let cachedRevision = surface.geometryRevision
for frame in 0..<120 { update(surface, time: 104, offset: 20_000 + Double(frame)) }
require(surface.geometryRevision == cachedRevision, "Camera frames inside overscan must only transform the cached canvas")
update(surface, time: 104, scale: 5_000)
require(surface.isOverview && surface.tiles(time: 104).isEmpty, "World overview must bound the number of layers")
let overviewRevision = surface.geometryRevision
for frame in 0..<120 { update(surface, time: 104, scale: 5_000 + Double(frame)) }
require(surface.geometryRevision == overviewRevision, "Overview must reuse its raster throughout small pinch/pan changes")

// A long route history must not be re-queried/re-projected for every camera frame.
let history = (0..<20_000).map { i in
    let p = unproject(CGPoint(x: Double(i % 200) * 3, y: Double(i / 200) * 9))
    return TornPaperRenderer.Segment(start: p, end: MKMapPoint(x: p.x + 160, y: p.y + 300))
}
let stress = MidnightHexSurface(segments: history)
var conversions = 0
let started = ProcessInfo.processInfo.systemUptime
for frame in 0..<240 {
    stress.updateViewport(bounds, time: 200 + Double(frame) / 60,
        unproject: { unproject($0, scale: 50 + Double(frame) * 0.3) },
        project: { conversions += 1; return project($0) })
}
let elapsed = ProcessInfo.processInfo.systemUptime - started
require(conversions <= 3, "Projection work must stay constant, not grow with cells or route history")
require(stress.geometryRevision < 20, "Pinch must coalesce coverage rebuilds")
require(stress.tiles(reduceMotion: true).count < 1_800, "Detail layer budget must remain bounded")
print("20k segments / 240 camera frames: \(String(format: "%.3f", elapsed))s, \(stress.geometryRevision) rebuilds, \(conversions) projection calls")
update(stress, time: 205, scale: 250)
let rasterStart = ProcessInfo.processInfo.systemUptime
let raster = MidnightHexOverview.image(world: stress.renderBounds, segments: stress.overviewSegments)
require(raster != nil && max(raster!.width, raster!.height) <= 1_200,
    "Overview texture must remain bounded independently of zoom or route history")
let rasterBytes = raster!.dataProvider!.data!
let rasterPixels = CFDataGetBytePtr(rasterBytes)!
var hasClearMap = false, hasCoveredMap = false
for y in stride(from: 0, to: raster!.height, by: 4) {
    for x in stride(from: 0, to: raster!.width, by: 4) {
        let alpha = rasterPixels[y * raster!.bytesPerRow + x * 4 + 3]
        hasClearMap = hasClearMap || alpha == 0
        hasCoveredMap = hasCoveredMap || alpha == 255
    }
}
require(hasClearMap && hasCoveredMap, "Overview must preserve transparent route holes and opaque unvisited areas")
print("Overview raster (background worker): \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - rasterStart))s")

// The layer-to-image threshold must NOT turn the hexes into a solid cover.
func distinctCoveredColors(_ image: CGImage) -> Int {
    let data = image.dataProvider!.data!, pixels = CFDataGetBytePtr(data)!
    var colors: Set<UInt32> = []
    for y in stride(from: 0, to: image.height, by: 3) {
        for x in stride(from: 0, to: image.width, by: 3) {
            let i = y * image.bytesPerRow + x * 4
            guard pixels[i + 3] == 255 else { continue }
            colors.insert(UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2]))
        }
    }
    return colors.count
}
let mediumWorld = CGRect(x: mapCenter.x - 30_000, y: mapCenter.y - 60_000, width: 60_000, height: 120_000)
let mediumStart = ProcessInfo.processInfo.systemUptime
let mediumImage = MidnightHexOverview.image(world: mediumWorld, segments: [])!
require(distinctCoveredColors(mediumImage) > 100, "Medium zoom must keep the actual beveled, textured tile sprites")
print("Medium overview sprites: \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - mediumStart))s")
let farWorld = CGRect(x: mapCenter.x - 100_000, y: mapCenter.y - 200_000, width: 200_000, height: 400_000)
let farImage = MidnightHexOverview.image(world: farWorld, segments: [])!
print("Far zoom tile colors: \(distinctCoveredColors(farImage))")
require(distinctCoveredColors(farImage) > 10, "Far zoom must retain geographic hex artwork, not a flat fill")
let worldStart = ProcessInfo.processInfo.systemUptime
let worldImage = MidnightHexOverview.image(world: CGRect(x: 0, y: 0,
    width: MKMapSize.world.width, height: MKMapSize.world.height), segments: [])
require(worldImage?.width == 1_200, "World-scale tiling must not allocate individual geographic cells")
require(MidnightHexOverview.image(world: mediumWorld, segments: [], isCancelled: { true }) == nil,
    "Obsolete overview jobs must terminate before rendering thousands of pieces")
print("World overview: \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - worldStart))s")

let route = [TornPaperRenderer.Segment(start: unproject(CGPoint(x: 160, y: 80)),
    end: unproject(CGPoint(x: 230, y: 760)))]
let routeSurface = MidnightHexSurface(segments: route)
update(routeSurface, time: 110)
require(routeSurface.contains(unproject(CGPoint(x: 195, y: 422))), "Route neighborhood must reveal the map")
require(!routeSurface.contains(unproject(CGPoint(x: 5, y: 422))), "Unvisited surroundings must remain covered")
let routeTiles = routeSurface.tiles(time: 112)
let initialRouteQueue = routeSurface.entryDelays
routeSurface.update(segments: [])
update(routeSurface, time: 112.1)
require(routeSurface.tiles(time: 112.1).count > routeTiles.count, "Filter changes must update coverage")
require(routeSurface.entryDelays == initialRouteQueue, "Filter changes must not create new falling tiles")
routeSurface.invalidate()
require(routeSurface.tiles(time: 114).isEmpty, "Leaving the mode must stop all drawing")

let reduceMotion = MidnightHexSurface(segments: [])
update(reduceMotion, time: 120)
require(reduceMotion.tiles(time: 120, reduceMotion: true).allSatisfy { $0.coverage == 1 && $0.fallProgress == nil },
    "Reduce Motion must show the final state immediately")

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/streetprint-midnight-hex")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (name, image) in [("hex-overview-medium", mediumImage), ("hex-overview-far", farImage)] {
    let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent("\(name).png") as CFURL,
        "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    require(CGImageDestinationFinalize(destination), "Must export overview regression image")
}
let preview = MidnightHexSurface(segments: route)
update(preview, time: 300)
func previewImage(time: Double) -> CGImage {
    let width = 780, height = 1688
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.025, green: 0.055, blue: 0.105, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: 0, y: Double(height)); context.scaleBy(x: 2, y: -2)
    context.setLineWidth(0.7)
    context.setStrokeColor(CGColor(red: 0.12, green: 0.22, blue: 0.35, alpha: 1))
    for x in stride(from: -100.0, to: 500, by: 19) {
        context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x + 80, y: 844))
    }
    for y in stride(from: 0.0, to: 844, by: 22) {
        context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: 390, y: y - 30))
    }
    context.strokePath()
    MidnightHexArtwork.draw(preview.tiles(time: time),
        radiusScale: MidnightHexSurface.mapUnitsPerLocalPoint / 50,
        project: { point in
            project(MKMapPoint(x: preview.mapOrigin.x + point.x * MidnightHexSurface.mapUnitsPerLocalPoint,
                y: preview.mapOrigin.y + point.y * MidnightHexSurface.mapUnitsPerLocalPoint))
        }, in: context)
    return context.makeImage()!
}
for (name, time) in [("filling", 300.85), ("settled", 302.0)] {
    let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent("hex-\(name).png") as CFURL,
        "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, previewImage(time: time), nil)
    require(CGImageDestinationFinalize(destination), "Must export preview")
}
print("PASS: geographic pan/zoom and stable identity, live-refresh animation preservation, entry-only visible queue, bounded overview, route reveal, Reduce Motion")
print("Artwork previews: \(output.path)")
