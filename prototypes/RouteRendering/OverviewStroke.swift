import AppKit
import MapKit

// Offscreen stroke parity is supplementary; attached-map validation is also
// required because MapKit can configure its native renderers differently.
for scale in [0.0005, 0.003, 0.02] {
    let center = MKMapPoint(CLLocationCoordinate2D(latitude: 35, longitude: 135))
    let rect = MKMapRect(x: center.x - 128 / scale, y: center.y - 128 / scale,
        width: 256 / scale, height: 256 / scale)
    let lines = [(20.0, 20.0, 230.0, 230.0), (20.0, 230.0, 230.0, 20.0),
                 (20.0, 20.0, 230.0, 230.0), (230.0, 230.0, 230.0, 50.0)].map { a, b, c, d in
        var points = [MKMapPoint(x: rect.minX + a / scale, y: rect.minY + b / scale),
                      MKMapPoint(x: rect.minX + c / scale, y: rect.minY + d / scale)]
        return MKPolyline(points: &points, count: 2)
    }
    for alpha in [0.67, 1.0] {
        func image(grouped: Bool) -> [UInt8] {
            let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
                bytesPerRow: 1024, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            let renderers: [MKOverlayPathRenderer] = grouped
                ? [MKMultiPolylineRenderer(multiPolyline: MKMultiPolyline(lines))]
                : lines.map { MKPolylineRenderer(polyline: $0) }
            for renderer in renderers {
                renderer.strokeColor = NSColor.blue.withAlphaComponent(alpha)
                renderer.lineWidth = 3; renderer.lineCap = .round; renderer.lineJoin = .round
                ctx.saveGState(); ctx.scaleBy(x: scale, y: scale)
                let origin = renderer.point(for: rect.origin)
                ctx.translateBy(x: -origin.x, y: -origin.y)
                renderer.draw(rect, zoomScale: scale, in: ctx); ctx.restoreGState()
            }
            return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: 256 * 1024))
        }
        let a = image(grouped: false), b = image(grouped: true)
        let changed = zip(a, b).filter { $0 != $1 }.count
        print("Native overview stroke scale=\(scale) alpha=\(alpha): differing bytes=\(changed)")
    }
}
