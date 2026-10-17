import AppKit
import MapKit
import ImageIO
import CoreText

@main
struct PaperPreview {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
        let detail = CommandLine.arguments.contains("--detail")
        let output = root.appendingPathComponent(detail
            ? "output/materials/torn-paper-v9-thin-edge/detail"
            : "output/materials/torn-paper-v9-thin-edge")
        let zoom = detail ? 16 : 15, columns = 2, rows = 4, scale = 2.0
        let center = MKMapPoint(CLLocationCoordinate2D(latitude: 35.701, longitude: 139.702))
        let tileUnits = MKMapSize.world.width / pow(2, Double(zoom))
        let mapRect = MKMapRect(x: center.x - Double(columns) * tileUnits / 2,
            y: center.y - Double(rows) * tileUnits / 2,
            width: Double(columns) * tileUnits, height: Double(rows) * tileUnits)
        let baseX = Int(floor(mapRect.minX / tileUnits)), baseY = Int(floor(mapRect.minY / tileUnits))
        let width = columns * 512, height = rows * 512
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let cachedMapURL = root.appendingPathComponent("output/materials/torn-paper-v2-curl/demo-map.png")
        let mapURL = FileManager.default.fileExists(atPath: cachedMapURL.path)
            ? cachedMapURL : output.appendingPathComponent("demo-map.png")
        if !FileManager.default.fileExists(atPath: mapURL.path) {
            let options = MKMapSnapshotter.Options()
            options.mapRect = mapRect
            options.size = CGSize(width: width, height: height)
            options.mapType = .standard
            options.pointOfInterestFilter = .excludingAll
            options.appearance = NSAppearance(named: .aqua)
            var done = false, failure: Error?
            let snapshotter = MKMapSnapshotter(options: options)
            snapshotter.start(with: .main) { snapshot, error in
                defer { done = true }
                guard let snapshot, let tiff = snapshot.image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
                    failure = error; return
                }
                do { try png.write(to: mapURL) } catch { failure = error }
            }
            let limit = Date().addingTimeInterval(50)
            while !done && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            precondition(done && failure == nil, "Map snapshot failed: \(String(describing: failure))")
        }
        func image(_ url: URL) -> CGImage {
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            return CGImageSourceCreateImageAtIndex(source, 0, nil)!
        }
        let sourceMap = image(mapURL)
        let map: CGImage
        if detail && mapURL == cachedMapURL {
            // The detailed viewport is the central half of the same cached
            // geographic rectangle. Paper is rendered anew at the finer zoom.
            map = sourceMap.cropping(to: CGRect(x: sourceMap.width / 4, y: sourceMap.height / 4,
                width: sourceMap.width / 2, height: sourceMap.height / 2))!
        } else {
            map = sourceMap
        }
        let paper = PaperMaterial(image: image(root.appendingPathComponent("Michi/Resources/Assets.xcassets/TornPaperSurface.imageset/paper-surface-v1.png")))!
        let edge = PaperEdgeMaterial(image: image(root.appendingPathComponent("Michi/Resources/Assets.xcassets/TornPaperFineEdge.imageset/thin-edge-v1.png")))!
        let encoded: [String] = [
            #"_syxE_htsYa@B?@RtBB@JFDB@TC@CBUDKBeBPeBJ?B?DG?m@DGv@e@GoCa@M@y@BoE\EICIG?}@BAI?ICAIC_Bd@gBf@iAL[?yBSaB@iAJwCj@{@T?A?QHC?BaAV?@C@AEHA?LsAh@_Ab@i@Pe@RgBbAaBx@MFo@ZQH"#,
            #"_syxE_htsYa@B?@RtBB@JFDB@TC@CBUDKBeBPeBJ?B?DG?m@DGv@e@GoCa@M@y@BoE\EICIG?}@BAI?ICAIC_Bd@gBf@iAL[?yBSaB@iAJwCj@{@T?A?QHC?BaAV?@C@AEHEA_DiA?aAAuAEmAE?C?CiEm@kBC"#,
            #"_syxE_htsYJAACIcAD?Gu@C?Eg@E@I@?AIy@EEsAb@uBt@U@mDVEF?H@b@m@@GGUFW?ABKHe@RINQJq@P}@NG?MES[C[@WGAy@K?DIr@s@PiEt@yAJ_AGcAKoA?iBGKC_CIGKCC?IG?g@@AJEHI@}BIw@CoAM?DARCAqAG]Bc@A}Di@EBKDQACGCGICwEUcFWw@CE?OAkAMmX}GWQgAqAM?A@CEc@e@If@Gh@CA_@IaA[cCq@aBa@o@]GCCBOAOdAA?_@Mm@S"#,
            #"qx{xEsrssYeB`AeAv@ACEOA?GF?[TuGEAQ?@_@DwAiA@sCAqHI?CDuALcC@E?S?EC?KA@c@@WEK_@KsCq@aJyBaK_CCCWG_@Ie@Mg@a@GE?BE?D@?BMr@MCOA[I}@YW[m@{@UMiAYkBc@?CBOA?_@Mm@S"#,
            #"y{{xEedtsYAVI?Y??ABYG?OAAVCVEBc@C{DQACGCGD}@E}@GAAMCEB_@C_BI?E?EC?KA@c@@WEK_@KsCq@aJyBaK_CCCWG_@Ie@Mg@a@GE?BE?D@?BMr@MCOA[I}@YW[m@{@UMiAYkBc@?CBOA?_@Mm@S"#,
            #"c_~xEmytsYj@N@DF@XHDUHq@@@JBDEj@XJF`Dx@fCt@`@JFi@Hg@BBb@f@@ABA@KF[CI@QJy@HKNQDA?EDIHOhBCBE?CBO@ALBd@m@PKVCF@TIPOHQHOFHDFKL"#,
            #"c_~xEmytsYj@N@DF@XHDUHq@@@JBDEj@XJF`Dx@fCt@`@JFi@Hg@BBb@f@@ABA@KF[CI@QJy@HKNQDA?EDIHOhBCBE?CBO@ALBd@m@PKVCF@TIPOHQHOJEl@CpCB?G?SX@?CFiHD??E@m@"#,
            #"c_~xEmytsYuGaBAB?BICMC@CF]BICAQKKEBKJc@ECSOBG@Gu@e@OEo@O@g@C?aBMaAE?G@SYAiBKIGAG@IEAa@KHi@Js@k@BmFL?@O`AAAMCEBuBi@cEmAyAc@cG}A{Ac@EG@AJGPUP_@RWr@S\SD@pEv@"#
        ]
        func decode(_ encoded: String) -> [MKMapPoint] {
            let data = Array(encoded.utf8)
            var i = 0, lat = 0, lon = 0, points: [MKMapPoint] = []
            func read() -> Int {
                var result = 0, shift = 0, byte = 0
                repeat {
                    byte = Int(data[i]) - 63; i += 1
                    result |= (byte & 31) << shift; shift += 5
                } while byte >= 32
                return result & 1 == 1 ? ~(result >> 1) : result >> 1
            }
            while i < data.count {
                lat += read(); lon += read()
                points.append(MKMapPoint(CLLocationCoordinate2D(latitude: Double(lat) / 100000, longitude: Double(lon) / 100000)))
            }
            return points
        }
        let paths = encoded.map(decode)
        var previews: [CGImage] = []
        for count in [1, paths.count] {
            let paths = Array(paths.prefix(count))
            let segments = paths.flatMap { path in zip(path, path.dropFirst()).map { TornPaperRenderer.Segment(start: $0.0, end: $0.1) } }
            let renderer = TornPaperRenderer(segments: segments, darkPaper: false, material: paper, edgeMaterial: edge)
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(map, in: CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setStrokeColor(CGColor(red: 0.12, green: 0.34, blue: 0.53, alpha: 0.95))
            ctx.setLineWidth(3.2); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            func screen(_ p: MKMapPoint) -> CGPoint {
                CGPoint(x: (p.x - mapRect.minX) / mapRect.width * Double(width),
                    y: Double(height) - (p.y - mapRect.minY) / mapRect.height * Double(height))
            }
            for path in paths {
                guard let first = path.first else { continue }
                ctx.move(to: screen(first))
                for p in path.dropFirst() { ctx.addLine(to: screen(p)) }
                ctx.strokePath()
            }
            for y in 0...rows { for x in 0...columns {
                let tilePath = MKTileOverlayPath(x: baseX + x, y: baseY + y, z: zoom, contentScaleFactor: scale)
                let tile = renderer.render(at: tilePath, screenPointsPerTileUnit: 1)!
                let tileX = (Double(baseX + x) * tileUnits - mapRect.minX) / tileUnits * 512
                let tileY = Double(height) - (Double(baseY + y + 1) * tileUnits - mapRect.minY) / tileUnits * 512
                ctx.draw(tile, in: CGRect(x: tileX, y: tileY, width: 512, height: 512))
            }}
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
            ctx.fill(CGRect(x: 8, y: 8, width: 140, height: 25))
            let label = NSAttributedString(string: "Map data © Apple", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.darkGray
            ])
            ctx.textPosition = CGPoint(x: 14, y: 15)
            CTLineDraw(CTLineCreateWithAttributedString(label), ctx)
            let rendered = ctx.makeImage()!
            previews.append(rendered)
            let png = CGImageDestinationCreateWithURL(output.appendingPathComponent(count == 1 ? "paper-first-route.png" : "paper-map-preview.png") as CFURL,
                "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(png, rendered, nil); precondition(CGImageDestinationFinalize(png))
        }
        let gif = CGImageDestinationCreateWithURL(output.appendingPathComponent("paper-route-growth.gif") as CFURL, "com.compuserve.gif" as CFString, 2, nil)!
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in previews {
            let thumb = CGContext(data: nil, width: width / 2, height: height / 2, bitsPerComponent: 8,
                bytesPerRow: width / 2 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            thumb.interpolationQuality = .high
            thumb.draw(frame, in: CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
            CGImageDestinationAddImage(gif, thumb.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.8]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(gif))
        print("Native paper tiles over a MapKit snapshot: 1 route vs \(paths.count) routes; \(output.path)")
    }
}
