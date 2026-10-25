import MapKit
import SwiftUI

enum WalkingCourseStyle {
    static let accent = Color(red: 0.90, green: 0.38, blue: 0.22)
    static let uiAccent = UIColor(red: 0.90, green: 0.38, blue: 0.22, alpha: 1)
}

/// Native material keeps the live map visible without snapshotting it on every pan.
private struct WalkingCourseGlass: ViewModifier {
    let theme: AppTheme
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(theme.prefersDarkMap ? Color(red: 0.04, green: 0.10, blue: 0.16) : .white)
                } else {
                    shape.fill(.ultraThinMaterial)
                        .environment(\.colorScheme, theme.prefersDarkMap ? .dark : .light)
                        .overlay(shape.fill(theme.prefersDarkMap
                            ? Color(red: 0.03, green: 0.09, blue: 0.15).opacity(0.35)
                            : .white.opacity(0.32)))
                }
            }
            .overlay(shape.strokeBorder(.white.opacity(theme.prefersDarkMap ? 0.14 : 0.65), lineWidth: 0.6))
            .shadow(color: .black.opacity(theme.prefersDarkMap ? 0.16 : 0.07), radius: 10, y: 3)
    }
}

struct WalkingCourseHeader: View {
    @ObservedObject var planner: WalkingCoursePlanner
    let theme: AppTheme
    let japanese: Bool
    let onSearch: () -> Void
    let onChangeDuration: (Int) -> Void
    let onGenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(planner.direction.opening == 360 ? text("全方位", "All directions")
                    : text("地図で方角を調整", "Adjust direction on map"))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text("\(Int(planner.direction.opening.rounded()))°").monospacedDigit()
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(theme.foregroundColor.opacity(0.65))
            .padding(.horizontal, 12)

            HStack(spacing: 0) {
                Button(action: onSearch) {
                    selector(label: text("出発地", "Starting point"),
                        value: planner.originName.isEmpty ? text("選択", "Choose") : planner.originName)
                }
                .accessibilityLabel(text("出発地を変更", "Change starting point"))
                .accessibilityValue(planner.originName)
                Rectangle().fill(theme.foregroundColor.opacity(0.12)).frame(width: 0.5, height: 28)
                Menu {
                    ForEach(CourseTravelMode.allCases) { mode in
                        Button { planner.setTravelMode(mode) } label: {
                            Label(mode.title(japanese: japanese), systemImage: planner.travelMode == mode ? "checkmark" : mode.symbol)
                        }
                    }
                } label: {
                    selector(label: text("手段", "Mode"), value: planner.travelMode.title(japanese: japanese))
                }
                .accessibilityLabel(text("検索する移動手段", "Route travel mode"))
                .accessibilityValue(planner.travelMode.title(japanese: japanese))
                Rectangle().fill(theme.foregroundColor.opacity(0.12)).frame(width: 0.5, height: 28)
                Menu {
                    ForEach([20, 30, 60], id: \.self) { minutes in
                        Button { onChangeDuration(minutes) } label: {
                            if planner.minutes == minutes {
                                Label(text("\(minutes)分", "\(minutes) min"), systemImage: "checkmark")
                            } else { Text(text("\(minutes)分", "\(minutes) min")) }
                        }
                    }
                } label: {
                    selector(label: text("所要時間", "Duration"),
                        value: text("\(planner.minutes)分", "\(planner.minutes) min"))
                }
                .accessibilityLabel(text("所要時間", "Duration"))
                .accessibilityValue(text("\(planner.minutes)分", "\(planner.minutes) minutes"))

                Button(action: onGenerate) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                        Text(text("検索", "Search")).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: japanese ? 68 : 74, height: 62)
                    .background(WalkingCourseStyle.accent.opacity(planner.isLoading ? 0.62 : 0.96))
                    .contentShape(Rectangle())
                }
                .disabled(planner.isLoading)
                .accessibilityLabel(text("\(planner.travelMode.title(japanese: true))コースを探す", "Find \(planner.travelMode.title(japanese: false).lowercased()) courses"))
            }
            .buttonStyle(.plain)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .modifier(WalkingCourseGlass(theme: theme, radius: 22))
        }
        .foregroundStyle(theme.foregroundColor)
        .frame(maxWidth: 430)
        .padding(.horizontal, 18)
    }

    private func selector(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2.weight(.medium))
                .foregroundStyle(theme.foregroundColor.opacity(0.58))
                .lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 5) {
                Text(value).font(.subheadline.weight(.semibold))
                    .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.8)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
    }
    private func text(_ ja: String, _ en: String) -> String { japanese ? ja : en }
}

struct WalkingCourseCard: View {
    @ObservedObject var planner: WalkingCoursePlanner
    let theme: AppTheme
    let japanese: Bool
    let onRetain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let course = planner.selectedCourse {
                HStack {
                    (Text(String(format: "%02d", planner.selection + 1)).fontWeight(.semibold)
                        + Text(String(format: " / %02d", planner.courses.count))
                            .foregroundColor(theme.foregroundColor.opacity(0.42)))
                        .font(.system(size: 16)).monospacedDigit()
                    Spacer()
                    Button(action: onRetain) {
                        Label(planner.retainedCourse?.id == course.id ? text("保存済み", "Saved")
                            : planner.retainedCourse == nil ? text("地図に残す", "Keep on map")
                            : text("このコースに変更", "Replace saved"), systemImage: "pin")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(WalkingCourseStyle.accent)
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .disabled(planner.retainedCourse?.id == course.id)
                    HStack(spacing: 2) {
                        courseArrow("chevron.left", label: text("前のコース", "Previous course"), offset: -1)
                        courseArrow("chevron.right", label: text("次のコース", "Next course"), offset: 1)
                    }
                }
                Rectangle().fill(theme.foregroundColor.opacity(0.10)).frame(height: 0.5)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    metric(prefix: text("約", "~"), value: "\(Int((course.seconds / 60).rounded()))",
                        unit: text("分", "min"))
                    metricDivider
                    metric(prefix: "", value: kilometers(course.distance), unit: "km")
                    metricDivider
                    metric(prefix: text("未踏 ", "New "), value: kilometers(course.unwalkedDistance), unit: "km")
                        .foregroundStyle(WalkingCourseStyle.accent)
                }
                .padding(.top, 2)
                Text(course.stops.isEmpty
                    ? text("地図を長押しで出発地を変更", "Long-press the map to change start")
                    : course.stops.prefix(2).map(\.name).joined(separator: " ・ "))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(theme.foregroundColor.opacity(0.58))
                    .lineLimit(1).truncationMode(.tail)
                if course.travelMode == .cycling, !course.advisories.isEmpty {
                    Text(course.advisories.prefix(2).joined(separator: " ・ "))
                        .font(.caption2).foregroundStyle(theme.foregroundColor.opacity(0.65))
                        .lineLimit(2)
                }
            } else if planner.isLoading {
                HStack(spacing: 12) {
                    ProgressView().tint(WalkingCourseStyle.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(planner.travelMode == .walking ? text("歩ける周回コースを探しています", "Finding walking loops")
                            : text("自転車の周回コースを探しています", "Finding cycling loops"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(planner.progress > WalkingCourseGeometry.maximumSearchTrials ? text("見どころを確認しています", "Checking nearby places")
                            : text("候補を確認中 \(planner.progress) / \(WalkingCourseGeometry.maximumSearchTrials)", "Checking candidates \(planner.progress) / \(WalkingCourseGeometry.maximumSearchTrials)"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 80)
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(planner.errorMessage ?? (planner.travelMode == .walking ? text("まだ歩いていない道へ", "Find somewhere new")
                            : text("まだ走っていない道へ", "Discover new cycling routes")))
                            .font(.system(size: 13, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(planner.travelMode == .walking
                            ? text("徒歩履歴から、約\(planner.minutes)分の周回を提案", "About \(planner.minutes)-min loops based on your walks")
                            : text("自転車履歴から、約\(planner.minutes)分の周回を提案", "About \(planner.minutes)-min loops based on your rides"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 80)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.foregroundColor)
        .padding(.horizontal, 16).padding(.top, 7).padding(.bottom, 14)
        .frame(maxWidth: 430, alignment: .leading)
        .modifier(WalkingCourseGlass(theme: theme, radius: 22))
        .padding(.horizontal, 18).padding(.bottom, 24)
        .accessibilityHint(text("未踏距離は選択した移動手段の記録履歴との照合による推定。立ち寄り時間は含みません。",
            "New distance is estimated from recorded history for the selected travel mode. Time excludes stops."))
    }

    private func courseArrow(_ icon: String, label: String, offset: Int) -> some View {
        Button { planner.select(offset) } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(theme.foregroundColor.opacity(0.12), lineWidth: 0.8))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .disabled(planner.courses.count < 2)
    }

    private var metricDivider: some View {
        Rectangle().fill(theme.foregroundColor.opacity(0.13)).frame(width: 0.5, height: 16)
    }

    private func metric(prefix: String, value: String, unit: String) -> some View {
        (Text(prefix).font(.system(size: 11, weight: .medium))
            + Text(value).font(.system(size: 20, weight: .semibold))
            + Text(" \(unit)").font(.system(size: 11, weight: .medium)))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func text(_ ja: String, _ en: String) -> String { japanese ? ja : en }
    private func kilometers(_ value: Double) -> String { String(format: "%.1f", value / 1_000) }
}

struct RetainedWalkingCourseControl: View {
    let theme: AppTheme
    let japanese: Bool
    var travelMode: CourseTravelMode = .walking
    let onFocus: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onFocus) {
                Label(travelMode == .cycling ? (japanese ? "自転車コース表示中" : "Cycling course on map")
                    : (japanese ? "コース表示中" : "Course on map"), systemImage: travelMode == .cycling
                        ? "bicycle" : "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.leading, 13).padding(.trailing, 3)
                    .frame(height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(japanese ? "保存コースの全体を表示" : "Show saved course")
            Button(action: onClear) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(japanese ? "コース表示を解除" : "Remove saved course")
        }
        .buttonStyle(.plain)
        .foregroundStyle(WalkingCourseStyle.accent)
        .modifier(WalkingCourseGlass(theme: theme, radius: 22))
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct WalkingCourseOriginSearch: View {
    let center: CLLocationCoordinate2D?
    let japanese: Bool
    let onCurrentLocation: () -> Void
    let onSelect: (MKMapItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var items: [MKMapItem] = []
    @State private var isLoading = false
    @State private var failed = false
    var body: some View {
        NavigationStack {
            List {
                Button {
                    onCurrentLocation(); dismiss()
                } label: { Label(text("現在地から", "From current location"), systemImage: "location.fill") }
                if isLoading { ProgressView() }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button { onSelect(item); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name ?? text("指定地点", "Selected place"))
                            Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !query.isEmpty && !isLoading && items.isEmpty {
                    Text(failed ? text("検索できませんでした", "Search unavailable") : text("場所が見つかりません", "No places found"))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(text("出発地", "Starting point"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: text("駅・公園・場所を検索", "Station, park or place"))
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(text("閉じる", "Close")) { dismiss() }
            } }
            .task(id: query) { await search() }
        }.presentationDetents([.medium, .large])
    }
    @MainActor private func search() async {
        items = []; failed = false
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { isLoading = false; return }
        isLoading = true
        do {
            try await Task.sleep(nanoseconds: 400_000_000)
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            if let center { request.region = MKCoordinateRegion(center: center, latitudinalMeters: 12_000, longitudinalMeters: 12_000) }
            let search = MKLocalSearch(request: request)
            let response = try await withTaskCancellationHandler { try await search.start() } onCancel: { search.cancel() }
            try Task.checkCancellation()
            items = Array(response.mapItems.prefix(10)); isLoading = false
        } catch { if !Task.isCancelled { failed = true; isLoading = false } }
    }
    private func text(_ ja: String, _ en: String) -> String { japanese ? ja : en }
}
