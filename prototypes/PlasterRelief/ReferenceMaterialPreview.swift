import AppKit
import SwiftUI
import ImageIO

// Asset-consuming native view, isolated from the iOS app. Tests the material
// over a real MapKit snapshot; it is not a generated picture of a fake map.
@main
struct ReferenceMaterialPreview {
    @MainActor
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent("output/materials/reference-relief-v4")
        let overlayURL = output.appendingPathComponent("plaster-overlay.png")
        let mapURL = root.appendingPathComponent("output/materials/relief-study-v1/map-background.png")
        func cgImage(_ url: URL) -> CGImage {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Missing \(url.path)") }
            return image
        }
        let overlayCG = cgImage(overlayURL), mapCG = cgImage(mapURL)
        // Check actual transparency; a black/checkerboard background is not a
        // valid material. Also require near-opaque plaster top faces (the
        // generated PNG can encode alpha 254 instead of 255 on solid faces).
        let w = overlayCG.width, h = overlayCG.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes {
            let context = CGContext(data: $0.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(overlayCG, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var clear = 0, opaque = 0, partial = 0
        for i in stride(from: 3, to: rgba.count, by: 4) {
            if rgba[i] == 0 { clear += 1 }
            else if rgba[i] >= 250 { opaque += 1 }
            else { partial += 1 }
        }
        precondition(clear > w * h / 5 && opaque > w * h / 5, "Overlay must contain real clear holes and near-opaque plaster")
        let overlay = NSImage(cgImage: overlayCG, size: CGSize(width: w, height: h))
        let map = NSImage(cgImage: mapCG, size: CGSize(width: mapCG.width, height: mapCG.height))
        let content = ZStack(alignment: .bottomLeading) {
            Image(nsImage: map).resizable().scaledToFill()
                .frame(width: CGFloat(w), height: CGFloat(h)).clipped()
                .saturation(0.50).contrast(0.88)
                .overlay(Color.white.opacity(0.09))
            Image(nsImage: overlay).resizable().frame(width: CGFloat(w), height: CGFloat(h))
            Text("Map data © Apple")
                .font(.system(size: 13)).foregroundStyle(Color.black.opacity(0.65))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color.white.opacity(0.84)).padding(10)
        }
        .frame(width: CGFloat(w), height: CGFloat(h))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let rendered = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else {
            fatalError("Native material view render failed")
        }
        try png.write(to: output.appendingPathComponent("reference-material-preview.png"))
        print("Native view rendered at \(w)×\(h); alpha validation passed: clear=\(clear), opaque=\(opaque), partial=\(partial)")
        print(output.appendingPathComponent("reference-material-preview.png").path)
    }
}
