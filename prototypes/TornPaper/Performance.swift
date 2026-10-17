import Foundation
import MapKit
import ImageIO

@main
struct PaperPerformance {
    static func main() {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let url = root.appendingPathComponent("Michi/Resources/Assets.xcassets/TornPaperFineEdge.imageset/thin-edge-v1.png")
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let material = PaperEdgeMaterial(image: CGImageSourceCreateImageAtIndex(source, 0, nil)!)!
        let zoom = 16
        let center = MKMapPoint(CLLocationCoordinate2D(latitude: 35.70, longitude: 139.71))
        let tileSide = MKMapSize.world.width / pow(2, Double(zoom))
        let bx = Int(center.x / tileSide), by = Int(center.y / tileSide)
        // A local dense history plus many distant streets, not personal data.
        var routes: [TornPaperRenderer.Segment] = []
        for i in 0..<20000 {
            let x = Double(bx) * tileSide + Double(i % 200 - 100) * 180
            let y = Double(by) * tileSide + Double(i / 200 - 50) * 180
            routes.append(.init(start: .init(x: x, y: y), end: .init(x: x + 130, y: y + Double(i % 3) * 60)))
        }
        #if PAPER_BASELINE
        let paper = TornPaperRenderer(segments: routes, darkPaper: false, material: nil, edgeMaterial: material)
        let scales = [3.0]
        #else
        let paper = TornPaperRenderer(segments: routes, darkPaper: false, material: nil,
            edgeMaterial: material, segmentIndex: PaperSegmentIndex(segments: routes))
        let scales = [0.5, 2.0, 3.0]
        #endif
        for scale in scales {
            var times: [Double] = []
            for _ in 0..<5 {
                let start = ProcessInfo.processInfo.systemUptime
                for y in 0..<2 { for x in 0..<2 {
                    let path = MKTileOverlayPath(x: bx + x, y: by + y, z: zoom, contentScaleFactor: scale)
                    precondition(paper.render(at: path, screenPointsPerTileUnit: 1) != nil)
                }}
                times.append(ProcessInfo.processInfo.systemUptime - start)
            }
            print("20,000 segments, four tiles, scale \(scale), median \(String(format: "%.1f", times.sorted()[2] * 1000)) ms")
        }
    }
}
