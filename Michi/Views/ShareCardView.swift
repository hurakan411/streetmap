import SwiftUI

struct ShareCardView: View {
    let segments: [WeightedSegment]
    let remixSnapshot: RemixViewportSnapshot?
    let mapImage: UIImage?
    let stats: WalkStats
    let rangeLabel: String
    let theme: AppTheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 地図あり／経路だけのどちらも、背景をカードいっぱいに敷く。
            RouteArtwork(segments: segments, remixSnapshot: remixSnapshot, mapImage: mapImage, theme: theme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ShareStatsPanel(stats: stats, rangeLabel: rangeLabel, theme: theme)
                .padding(.leading, 16)
                .padding(.top, 18)

            HStack(spacing: 7) {
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath.fill")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Street Print")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Your Personal Route Map")
                        .font(.system(size: 7.5, weight: .bold))
                        .tracking(0.55)
                        .textCase(.uppercase)
                        .opacity(0.65)
                }
            }
            .foregroundStyle(theme.foregroundColor)
            .shadow(color: theme.backgroundColor.opacity(0.9), radius: 3)
            .padding(.trailing, 18)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .foregroundStyle(theme.foregroundColor)
        .background(theme.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private var distanceText: String {
        if stats.distance < 1_000 { return "\(Int(stats.distance.rounded()))" }
        let km = stats.distance / 1_000
        return km >= 100 ? String(format: "%.0f", km) : String(format: "%.1f", km)
    }

}

private struct ShareStatsPanel: View {
    let stats: WalkStats
    let rangeLabel: String
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(rangeLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.foregroundColor.opacity(0.72))

            item(label: "新しい道", value: "\(stats.newRoads)", unit: "本")
            item(label: "移動距離", value: distanceText, unit: stats.distance < 1_000 ? "m" : "km")
            item(label: "アクティブ日数", value: "\(stats.activeDays)", unit: "日")
        }
        .foregroundStyle(theme.foregroundColor)
        .shadow(color: theme.backgroundColor.opacity(0.88), radius: 3)
    }

    private var distanceText: String {
        if stats.distance < 1_000 { return "\(Int(stats.distance.rounded()))" }
        let km = stats.distance / 1_000
        return km >= 100 ? String(format: "%.0f", km) : String(format: "%.1f", km)
    }

    private func item(label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.foregroundColor.opacity(0.68))
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 38, weight: .regular))
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                Text(LocalizedStringKey(unit))
                    .font(.system(size: 13, weight: .medium))
            }
            Rectangle()
                .fill(theme.foregroundColor.opacity(0.26))
                .frame(width: 92, height: 0.75)
        }
    }
}

private struct RouteArtwork: View {
    let segments: [WeightedSegment]
    let remixSnapshot: RemixViewportSnapshot?
    let mapImage: UIImage?
    let theme: AppTheme

    var body: some View {
        Canvas { context, size in
            if let mapImage {
                let image = Image(uiImage: mapImage)
                let sourceAspect = mapImage.size.width / max(1, mapImage.size.height)
                let targetAspect = size.width / max(1, size.height)
                let drawRect: CGRect
                if sourceAspect > targetAspect {
                    let width = size.height * sourceAspect
                    drawRect = CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
                } else {
                    let height = size.width / sourceAspect
                    drawRect = CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
                }
                context.draw(image, in: drawRect)
                return
            }
            if let remixSnapshot {
                drawRemixedRoutes(remixSnapshot, context: &context, size: size)
                return
            }
            guard !segments.isEmpty else {
                context.draw(
                    Text("移動すると、ここに道が現れます")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.foregroundColor.opacity(0.35)),
                    at: CGPoint(x: size.width / 2, y: size.height / 2)
                )
                return
            }
            let averageLatitude = segments.reduce(0) { $0 + $1.start.latitude } / Double(segments.count)
            let longitudeScale = cos(averageLatitude * .pi / 180)
            let xs = segments.flatMap { [$0.start.longitude * longitudeScale, $0.end.longitude * longitudeScale] }
            let ys = segments.flatMap { [$0.start.latitude, $0.end.latitude] }
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
            let width = max(0.000001, maxX - minX)
            let height = max(0.000001, maxY - minY)
            let padding: CGFloat = 10
            let scale = min((size.width - padding * 2) / width, (size.height - padding * 2) / height)
            let drawnWidth = width * scale
            let drawnHeight = height * scale
            let offsetX = (size.width - drawnWidth) / 2
            let offsetY = (size.height - drawnHeight) / 2

            for segment in segments.sorted(by: { $0.frequency < $1.frequency }) {
                let startX = offsetX + (segment.start.longitude * longitudeScale - minX) * scale
                let startY = size.height - (offsetY + (segment.start.latitude - minY) * scale)
                let endX = offsetX + (segment.end.longitude * longitudeScale - minX) * scale
                let endY = size.height - (offsetY + (segment.end.latitude - minY) * scale)
                var path = Path()
                path.move(to: CGPoint(x: startX, y: startY))
                path.addLine(to: CGPoint(x: endX, y: endY))
                let alpha = min(1, 0.45 + log2(Double(segment.frequency) + 1) * 0.2)
                let width = (0.8 + min(3.3, CGFloat(log2(Double(segment.frequency) + 1)))) * theme.lineScale
                let segmentColor = theme.routeColor
                context.stroke(
                    path,
                    with: .color(segmentColor.opacity(segment.isEstimated ? min(alpha, 0.58) : alpha)),
                    style: StrokeStyle(
                        lineWidth: width,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
    }

    private func drawRemixedRoutes(
        _ snapshot: RemixViewportSnapshot,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        guard !snapshot.segments.isEmpty else {
            context.draw(
                Text("この範囲に経路がありません")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.foregroundColor.opacity(0.35)),
                at: CGPoint(x: size.width / 2, y: size.height / 2)
            )
            return
        }

        let targetAspect = max(0.1, snapshot.viewportAspectRatio)
        let availableAspect = size.width / max(1, size.height)
        let drawingRect: CGRect
        if availableAspect > targetAspect {
            let width = size.height * targetAspect
            drawingRect = CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        } else {
            let height = size.width / targetAspect
            drawingRect = CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }

        for segment in snapshot.segments.sorted(by: { $0.frequency < $1.frequency }) {
            var path = Path()
            path.move(to: CGPoint(
                x: drawingRect.minX + segment.start.x * drawingRect.width,
                y: drawingRect.minY + segment.start.y * drawingRect.height
            ))
            path.addLine(to: CGPoint(
                x: drawingRect.minX + segment.end.x * drawingRect.width,
                y: drawingRect.minY + segment.end.y * drawingRect.height
            ))
            let alpha = min(1, 0.48 + log2(Double(segment.frequency) + 1) * 0.19)
            let width = (1.1 + min(4.2, CGFloat(log2(Double(segment.frequency) + 1)) * 1.15)) * theme.lineScale
            let color = theme.routeColor
            context.stroke(
                path,
                with: .color(color.opacity(segment.isEstimated ? min(alpha, 0.58) : alpha)),
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            )
        }
    }
}
