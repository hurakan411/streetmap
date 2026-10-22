import SwiftUI
import WidgetKit

struct RecordingEntry: TimelineEntry {
    let date: Date
    let state: RecordingWidgetState
}

struct RecordingProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordingEntry {
        RecordingEntry(date: .now, state: RecordingWidgetState(
            recordingMode: .persistent, authorization: 3, isCollecting: true, isConfigured: true
        ))
    }
    func getSnapshot(in context: Context, completion: @escaping (RecordingEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : RecordingEntry(date: .now, state: RecordingWidgetStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordingEntry>) -> Void) {
        let entry = RecordingEntry(date: .now, state: RecordingWidgetStore.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

struct RecordingWidgetView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: RecordingEntry
    // Explicit family is used only by the standalone visual QA app.
    var previewFamily: WidgetFamily? = nil
    private var family: WidgetFamily { previewFamily ?? widgetFamily }
    private var state: RecordingWidgetState { entry.state }
    private var isDark: Bool { state.theme == "midnightPulse" }
    private var ink: Color { isDark ? Color(red: 0.88, green: 0.95, blue: 1) : Color(red: 0.10, green: 0.17, blue: 0.23) }
    private var accent: Color { Color(red: 0.14, green: 0.46, blue: 0.93) }
    private var inactive: Color { isDark ? Color(red: 0.51, green: 0.56, blue: 0.61) : Color(red: 0.57, green: 0.61, blue: 0.65) }
    private var isRecording: Bool {
        state.isConfigured && state.recordingMode != .off && !state.needsPermission && state.isCollecting
    }
    private var statusColor: Color { isRecording ? accent : inactive }
    private var background: Color {
        if isDark { return Color(red: 0.035, green: 0.085, blue: 0.13) }
        return state.theme == "paperAtlas" ? Color(red: 0.96, green: 0.94, blue: 0.90) : Color(red: 0.96, green: 0.97, blue: 0.98)
    }

    var body: some View {
        HStack(spacing: 14) {
            recordingPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if family == .systemMedium && state.isConfigured {
                Rectangle().fill(ink.opacity(0.10)).frame(width: 1)
                    .padding(.vertical, 5)
                capturePanel.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(ink)
        .containerBackground(background, for: .widget)
        .widgetURL(RecordingWidgetStore.homeURL)
    }

    private var recordingPanel: some View {
        VStack(spacing: 0) {
            Text("STREET PRINT")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.8)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            routeMark
            Spacer(minLength: 4)
            if !state.isConfigured {
                Text(state.text("タップして初期設定", "Tap to set up"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(height: 36)
            } else {
                if state.needsPermission {
                    Label(state.text("権限を確認", "Check permission"), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(ink.opacity(0.7))
                }
                HStack(spacing: 0) {
                    ForEach(RecordingMode.allCases) { mode in
                        recordingButton(mode)
                            .buttonStyle(.plain)
                            .accessibilityLabel(recordingAccessibilityTitle(mode))
                            .accessibilityAddTraits(state.recordingMode == mode ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var routeMark: some View {
        // One continuous route, not a live map or a looping animation.
        ZStack {
            WidgetRouteLine()
                .stroke(statusColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            Circle().fill(statusColor)
                .frame(width: 11, height: 11).position(x: 8, y: 40)
            Circle().fill(background)
                .overlay(Circle().stroke(statusColor, lineWidth: 3))
                .frame(width: 12, height: 12).position(x: 80, y: 10)
        }
        .frame(width: 88, height: 50)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.text("記録状態", "Recording status"))
        .accessibilityValue(state.needsPermission
            ? state.text("位置情報の権限が必要", "Location permission required")
            : isRecording ? state.text("記録オン", "Recording on") : state.text("記録停止中", "Recording stopped"))
    }

    private var capturePanel: some View {
        VStack(spacing: 0) {
            Text(state.text("記録する移動", "CAPTURE"))
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                ForEach(MovementCaptureMode.allCases) { mode in
                    Button(intent: SetMovementCaptureModeIntent(mode: mode)) {
                        Image(systemName: mode == .all ? "car.fill" : mode.symbol)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(captureIncludes(mode) ? accent : inactive)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background {
                                Circle().fill(background)
                                    .overlay(Circle().fill(captureIncludes(mode) ? accent.opacity(0.10) : ink.opacity(0.035)))
                                    .frame(width: 37, height: 37)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(captureAccessibilityTitle(mode))
                    .accessibilityAddTraits(state.movementMode == mode ? .isSelected : [])
                }
            }
            .background {
                GeometryReader { geometry in
                    let step = geometry.size.width / 3
                    Path { path in
                        path.move(to: CGPoint(x: step / 2, y: geometry.size.height / 2))
                        path.addLine(to: CGPoint(x: geometry.size.width - step / 2, y: geometry.size.height / 2))
                    }.stroke(inactive.opacity(0.25), lineWidth: 1.5)
                    Path { path in
                        path.move(to: CGPoint(x: step / 2, y: geometry.size.height / 2))
                        let count: CGFloat = state.movementMode == .all ? 2 : state.movementMode == .bicycle ? 1 : 0
                        path.addLine(to: CGPoint(x: step / 2 + step * count, y: geometry.size.height / 2))
                    }.stroke(accent, lineWidth: 1.5)
                }
            }
            Spacer(minLength: 8)
            Text(captureTitle(state.movementMode))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(height: 36)
        }
    }

    private func captureIncludes(_ mode: MovementCaptureMode) -> Bool {
        switch state.movementMode {
        case .walking: mode == .walking
        case .bicycle: mode != .all
        case .all: true
        }
    }

    @ViewBuilder
    private func recordingButton(_ mode: RecordingMode) -> some View {
        if state.requiresApp(for: mode) {
            Button(intent: SetRecordingModeInAppIntent(mode: mode)) {
                recordingOption(mode)
            }
        } else {
            Button(intent: SetRecordingModeIntent(mode: mode)) {
                recordingOption(mode)
            }
        }
    }

    private func recordingOption(_ mode: RecordingMode) -> some View {
        let selected = state.recordingMode == mode
        let color = selected ? (mode == .off ? inactive : accent) : ink.opacity(0.65)
        return VStack(spacing: 6) {
            Text(recordingTitle(mode))
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .lineLimit(1).minimumScaleFactor(0.75)
            Capsule().fill(selected ? color : .clear).frame(width: 24, height: 2)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, minHeight: 36)
        .contentShape(Rectangle())
    }

    private func recordingTitle(_ mode: RecordingMode) -> String {
        switch mode {
        case .persistent: state.text("常時", "Always")
        case .background: state.text("起動中", "Running")
        case .off: state.text("オフ", "Off")
        }
    }
    private func recordingAccessibilityTitle(_ mode: RecordingMode) -> String {
        mode == .background ? state.text("バックグラウンドまで記録", "Record while running, including background") : recordingTitle(mode)
    }
    private func captureTitle(_ mode: MovementCaptureMode) -> String {
        switch mode {
        case .walking: state.text("徒歩のみ", "Walking only")
        case .bicycle: state.text("自転車まで", "Walk + cycle")
        case .all: state.text("すべての移動", "All travel")
        }
    }
    private func captureAccessibilityTitle(_ mode: MovementCaptureMode) -> String {
        switch mode {
        case .walking: captureTitle(mode)
        case .bicycle: state.text("徒歩と自転車を記録", "Record walking and cycling")
        case .all: state.text("徒歩・自転車・自動車・電車を記録", "Record walking, cycling, cars and trains")
        }
    }
}

private struct WidgetRouteLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 88 * rect.width, y: rect.minY + y / 50 * rect.height)
        }
        path.move(to: point(8, 40))
        path.addLine(to: point(34, 40))
        path.addQuadCurve(to: point(44, 30), control: point(44, 40))
        path.addLine(to: point(44, 20))
        path.addQuadCurve(to: point(54, 10), control: point(44, 10))
        path.addLine(to: point(80, 10))
        return path
    }
}

struct StreetPrintRecordingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: RecordingWidgetStore.kind, provider: RecordingProvider()) { entry in
            RecordingWidgetView(entry: entry)
        }
        .configurationDisplayName("記録コントロール")
        .description("ホーム画面から記録モードと記録する移動を切り替えます。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#if !WIDGET_LAYOUT_STUDY
@main
struct StreetPrintWidgetBundle: WidgetBundle {
    var body: some Widget { StreetPrintRecordingWidget() }
}
#endif
