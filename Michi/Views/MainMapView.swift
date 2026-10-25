import CoreLocation
import MapKit
import StoreKit
import SwiftUI

struct MainMapView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsSettings = false
    @State private var sharePayload: SharePayload?
    @State private var recenterToken = 0
    @State private var hasRequestedInitialLocation = false
    @State private var isUIHidden = false
    @State private var isHidingUI = false
    @State private var revealPhase = 9
    @State private var revealTask: Task<Void, Never>?
    @State private var reviewRequestTask: Task<Void, Never>?
    @State private var scheduledReviewTrigger: ReviewRequestTrigger?
    @State private var animatedStats = WalkStats.zero
    @State private var remixSnapshot: RemixViewportSnapshot?
    @State private var sharesAfterRemix = false
    @State private var mapSnapshotRequestToken = 0
    @State private var sharesAfterMapSnapshot = false
    @State private var datePickerTarget: DatePickerTarget?
    @State private var selectedPlace: MapPlaceDetails?
    @StateObject private var coursePlanner = WalkingCoursePlanner()
    @State private var showsCourseOriginSearch = false
    @State private var previousCourseDisplayMode: MapDisplayMode?

    var body: some View {
        ZStack {
            MapCanvasView(
                segments: store.allWeightedSegments,
                segmentsSignature: store.segmentsSignature,
                livePoints: store.livePoints,
                stats: store.stats,
                visibleTransportModes: store.visibleTransportModes,
                showsPointsOfInterest: store.showsPointsOfInterest,
                mode: store.displayMode,
                theme: store.theme,
                recenterToken: recenterToken,
                targetLocation: mapTargetLocation,
                reservesBottomControlsSpace: !isUIHidden,
                onMapTap: {
                    if !coursePlanner.isPresented { toggleUIVisibility() }
                },
                onPlaceSelected: { place in
                    withAnimation(.snappy(duration: 0.24)) {
                        selectedPlace = place
                    }
                },
                onAnimatedStatsChanged: { nextStats in
                    withAnimation(.linear(duration: 2.0)) {
                        animatedStats = nextStats
                    }
                },
                onRemixSnapshotChanged: { snapshot in
                    remixSnapshot = snapshot
                    if sharesAfterRemix, snapshot != nil, store.displayMode == .routesOnly {
                        sharesAfterRemix = false
                        makeShareImage(snapshot: snapshot)
                    }
                },
                mapSnapshotRequestToken: mapSnapshotRequestToken,
                onMapSnapshotReady: { image in
                    guard sharesAfterMapSnapshot else { return }
                    sharesAfterMapSnapshot = false
                    guard let image else { return }
                    makeShareImage(mapImage: image)
                },
                planningCourse: coursePlanner.isPresented ? coursePlanner.selectedCourse : coursePlanner.retainedCourse,
                planningOrigin: coursePlanner.isPresented ? coursePlanner.origin : nil,
                isPlanningCourse: coursePlanner.isPresented,
                planningTravelMode: coursePlanner.travelMode,
                courseCameraRevision: coursePlanner.cameraRevision,
                onCourseOriginSelected: { coordinate in
                    coursePlanner.setOrigin(coordinate, name: courseText("指定地点", "Selected point"))
                },
                courseDirection: coursePlanner.direction,
                courseDirectionRadius: coursePlanner.travelMode.directionRadius(minutes: coursePlanner.minutes),
                courseDirectionJapanese: courseIsJapanese,
                onCourseDirectionChanged: { bearing, opening in
                    coursePlanner.setDirection(bearing: bearing, opening: opening)
                }
            )
            .ignoresSafeArea()

            if store.displayMode == .map && store.theme == .paperAtlas {
                store.theme.backgroundColor.opacity(0.09)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if !coursePlanner.isPresented && coursePlanner.retainedCourse == nil && !isUIHidden && store.displayRevision > 0 && store.allWeightedSegments.isEmpty && store.livePoints.isEmpty && revealPhase >= 3 {
                EmptyRouteView(theme: store.theme, hasHistory: !store.tracks.isEmpty)
                    .transition(.opacity)
            }

            if !isUIHidden {
                ZStack {
                    VStack {
                        HStack {
                            if !coursePlanner.isPresented {
                                VerticalStatsPanel(stats: animatedStats, theme: store.theme, revealPhase: revealPhase)
                            }
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(.leading, 16)
                    .padding(.top, 8)

                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            VStack(alignment: .trailing, spacing: 11) {
                                if !coursePlanner.isPresented {
                                FloatingButton(icon: "gearshape.fill", label: "設定", theme: store.theme) {
                                    showsSettings = true
                                }
                                .staggeredReveal(revealPhase, stage: 4)
                                }
                                FloatingButton(icon: "point.topleft.down.to.point.bottomright.curvepath", label: courseText("コース提案", "Route suggestions"), theme: store.theme) {
                                    if coursePlanner.isPresented { coursePlanner.close() }
                                    else {
                                        selectedPlace = nil
                                        previousCourseDisplayMode = store.displayMode
                                        store.displayMode = .map
                                        coursePlanner.open(at: mapTargetLocation?.coordinate, name: courseText("現在地", "Current location"))
                                    }
                                }
                                .overlay(Circle().stroke(coursePlanner.isPresented ? WalkingCourseStyle.accent : .clear, lineWidth: 1.5))
                                .staggeredReveal(revealPhase, stage: 4)
                                if !coursePlanner.isPresented {
                                FloatingButton(
                                    icon: "square.3.layers.3d",
                                    label: displayModeLabel,
                                    theme: store.theme
                                ) {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        cycleDisplayMode()
                                    }
                                }
                                .contextMenu {
                                    ForEach(MapDisplayMode.allCases, id: \.rawValue) { mode in
                                        Button {
                                            sharesAfterRemix = false
                                            store.displayMode = mode
                                        } label: {
                                            Label(mapModeName(mode), systemImage: store.displayMode == mode ? "checkmark" : mapModeSymbol(mode))
                                        }
                                    }
                                }
                                .disabled(coursePlanner.isPresented)
                                .staggeredReveal(revealPhase, stage: 5)
                                FloatingButton(icon: "square.and.arrow.up", label: "共有", theme: store.theme) {
                                    requestShare()
                                }
                                .disabled(coursePlanner.isPresented)
                                .staggeredReveal(revealPhase, stage: 6)
                                FloatingButton(icon: "location.fill", label: "現在地", theme: store.theme) {
                                    if store.recorder.authorizationStatus == .notDetermined {
                                        store.recorder.requestForegroundAuthorization()
                                    }
                                    store.refreshCurrentLocation()
                                    recenterToken += 1
                                }
                                .staggeredReveal(revealPhase, stage: 7)
                                TransportFilterControl(
                                    visibleModes: store.visibleTransportModes,
                                    theme: store.theme,
                                    onToggle: store.toggleTransportMode
                                )
                                .staggeredReveal(revealPhase, stage: 7)
                                }
                            }
                        }
                        .padding(.trailing, 18)
                        .padding(.bottom, coursePlanner.isPresented ? 270 : 112)
                    }

                    VStack {
                        Spacer()
                        if coursePlanner.isPresented {
                            VStack(spacing: 10) {
                                WalkingCourseHeader(planner: coursePlanner, theme: store.theme, japanese: courseIsJapanese,
                                    onSearch: { showsCourseOriginSearch = true },
                                    onChangeDuration: { coursePlanner.setMinutes($0) }, onGenerate: generateCourses)
                                WalkingCourseCard(planner: coursePlanner, theme: store.theme, japanese: courseIsJapanese,
                                    onRetain: {
                                        guard coursePlanner.retainSelectedCourse(japanese: courseIsJapanese) else { return }
                                        // Saving returns to the ordinary map, even if planning began from a hidden-map mode.
                                        previousCourseDisplayMode = nil
                                        store.displayMode = .map
                                        coursePlanner.close()
                                    })
                            }
                        } else { bottomControls }
                    }

                    if !coursePlanner.isPresented, coursePlanner.retainedCourse != nil {
                        VStack {
                            Spacer()
                            HStack {
                                RetainedWalkingCourseControl(theme: store.theme, japanese: courseIsJapanese,
                                    travelMode: coursePlanner.retainedCourse?.travelMode ?? .walking,
                                    onFocus: coursePlanner.focusRetainedCourse,
                                    onClear: { coursePlanner.clearRetainedCourse(japanese: courseIsJapanese) })
                                Spacer()
                            }
                            .padding(.leading, 16).padding(.bottom, 170)
                        }
                    }

                }
                .transition(.opacity)
            }

            if let selectedPlace {
                VStack {
                    Spacer()
                    PlaceInfoCard(place: selectedPlace, theme: store.theme) {
                        withAnimation(.snappy(duration: 0.24)) {
                            self.selectedPlace = nil
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, isUIHidden ? 18 : 154)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView()
                .environmentObject(store)
        }
        .alert(courseText("コースの保存", "Saved course"), isPresented: Binding(
            get: { coursePlanner.retentionError != nil },
            set: { if !$0 { coursePlanner.retentionError = nil } }
        )) {
            Button("OK") { coursePlanner.retentionError = nil }
        } message: {
            Text(coursePlanner.retentionError ?? "")
        }
        .onChange(of: store.showsWidgetRecordingSettings, initial: true) { _, shows in
            guard shows else { return }
            showsSettings = true
            store.showsWidgetRecordingSettings = false
        }
        .onChange(of: store.showsWidgetHome, initial: true) { _, shows in
            guard shows else { return }
            coursePlanner.close()
            showsCourseOriginSearch = false
            showsSettings = false
            sharePayload = nil
            datePickerTarget = nil
            selectedPlace = nil
            sharesAfterRemix = false
            sharesAfterMapSnapshot = false
            store.showsWidgetHome = false
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: [payload.image])
        }
        .sheet(item: $datePickerTarget) { target in
            RangeDatePickerSheet(target: target, store: store)
        }
        .sheet(isPresented: $showsCourseOriginSearch) {
            WalkingCourseOriginSearch(center: coursePlanner.origin ?? mapTargetLocation?.coordinate,
                japanese: courseIsJapanese,
                onCurrentLocation: {
                    if let coordinate = mapTargetLocation?.coordinate {
                        coursePlanner.setOrigin(coordinate, name: courseText("現在地", "Current location"))
                    } else { store.refreshCurrentLocation() }
                },
                onSelect: { item in
                    coursePlanner.setOrigin(item.placemark.coordinate, name: item.name ?? courseText("指定地点", "Selected point"))
                })
        }
        .onChange(of: coursePlanner.isPresented) { _, presented in
            if !presented, let previous = previousCourseDisplayMode {
                store.displayMode = previous
                previousCourseDisplayMode = nil
            }
        }
        .onChange(of: store.latestLocation?.timestamp) { _, _ in
            if coursePlanner.isPresented && coursePlanner.origin == nil, let coordinate = mapTargetLocation?.coordinate {
                coursePlanner.setOrigin(coordinate, name: courseText("現在地", "Current location"))
            }
        }
        .onAppear {
            scheduleReviewIfNeeded()

            guard !hasRequestedInitialLocation else { return }
            hasRequestedInitialLocation = true
            if store.recordingMode != .off && store.recorder.authorizationStatus == .notDetermined {
                store.recorder.requestForegroundAuthorization()
            } else if store.recordingMode == .persistent && store.recorder.authorizationStatus == .authorizedWhenInUse {
                store.recorder.requestBackgroundAuthorization()
            }
            store.refreshCurrentLocation()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                reviewRequestTask?.cancel()
                return
            }
            // 移動後にアプリへ戻った場合は、古い座標を再利用せず新しい測位を待って中央へ戻す。
            store.refreshCurrentLocation()
            recenterToken += 1
            scheduleReviewIfNeeded()
        }
        .onChange(of: store.reviewEligibleActiveDays) { _, _ in
            scheduleReviewIfNeeded()
        }
        .onDisappear { reviewRequestTask?.cancel() }
    }

    /// Simulator previews use a deterministic Shinjuku location so screenshots
    /// and route data stay aligned even when the Mac's simulated GPS changes.
    private var mapTargetLocation: CLLocation? {
        #if targetEnvironment(simulator)
        CLLocation(latitude: 35.6896, longitude: 139.7006)
        #else
        store.latestLocation
        #endif
    }

    private var courseIsJapanese: Bool { store.appLanguage.localeIdentifier.hasPrefix("ja") }
    private func courseText(_ ja: String, _ en: String) -> String { courseIsJapanese ? ja : en }
    private func generateCourses() {
        coursePlanner.generate(tracks: store.tracks, japanese: courseIsJapanese)
    }

    private var displayModeLabel: String {
        courseText("地図表示を切り替え：", "Change map mode: ") + mapModeName(store.displayMode)
    }

    private func mapModeName(_ mode: MapDisplayMode) -> String {
        switch mode {
        case .map: courseText("地図あり", "Full map")
        case .excavation: courseText("周辺を隠す", "Reveal walked areas")
        case .routesOnly: courseText("地図なし", "Routes only")
        }
    }

    private func mapModeSymbol(_ mode: MapDisplayMode) -> String {
        switch mode {
        case .map: "map"
        case .excavation: "square.3.layers.3d"
        case .routesOnly: "point.bottomleft.forward.to.point.topright.scurvepath"
        }
    }

    private func cycleDisplayMode() {
        switch store.displayMode {
        case .map: store.displayMode = .excavation
        case .excavation: store.displayMode = .routesOnly
        case .routesOnly: store.displayMode = .map
        }
        sharesAfterRemix = false
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            PeriodPicker(selection: $store.period, theme: store.theme)
                .staggeredReveal(revealPhase, stage: 8)

            HStack(spacing: 10) {
                Button {
                    datePickerTarget = .start
                } label: {
                    Text(dateLabel(store.selectedDateRange.lowerBound))
                        .frame(minWidth: 38, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("開始日を選択"))

                RangeSlider(
                    lower: $store.rangeStartFraction,
                    upper: $store.rangeEndFraction,
                    color: store.theme.interactionColor
                )
                .frame(height: 44)

                Button {
                    datePickerTarget = .end
                } label: {
                    Text(dateLabel(store.selectedDateRange.upperBound))
                        .frame(minWidth: 38, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("終了日を選択"))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(store.theme.foregroundColor.opacity(0.72))
            .staggeredReveal(revealPhase, stage: 9)
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: store.appLanguage.localeIdentifier)
        formatter.setLocalizedDateFormatFromTemplate(store.period == .today ? "H:mm" : "M/d")
        return formatter.string(from: date)
    }

    @MainActor
    private func toggleUIVisibility() {
        revealTask?.cancel()

        if isUIHidden || isHidingUI {
            isHidingUI = false
            isUIHidden = false
            let firstStage = min(9, max(1, revealPhase + 1))
            revealTask = Task { @MainActor in
                for stage in firstStage...9 {
                    try? await Task.sleep(nanoseconds: 72_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.24)) {
                        revealPhase = stage
                    }
                }
            }
        } else {
            isHidingUI = true
            let firstStage = min(8, max(0, revealPhase - 1))
            revealTask = Task { @MainActor in
                for stage in stride(from: firstStage, through: 0, by: -1) {
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeIn(duration: 0.2)) {
                        revealPhase = stage
                    }
                    try? await Task.sleep(nanoseconds: 72_000_000)
                }
                try? await Task.sleep(nanoseconds: 140_000_000)
                guard !Task.isCancelled else { return }
                isUIHidden = true
                isHidingUI = false
            }
        }
    }

    @MainActor
    private func requestShare() {
        if store.displayMode != .routesOnly {
            sharesAfterMapSnapshot = true
            mapSnapshotRequestToken &+= 1
            return
        }
        guard remixSnapshot != nil else {
            sharesAfterRemix = true
            store.displayMode = .routesOnly
            return
        }
        makeShareImage()
    }

    @MainActor
    private func makeShareImage(snapshot: RemixViewportSnapshot? = nil, mapImage: UIImage? = nil) {
        let content = ShareCardView(
            segments: store.weightedSegments,
            remixSnapshot: snapshot ?? remixSnapshot,
            mapImage: mapImage,
            stats: store.stats,
            rangeLabel: store.selectedRangeLabel,
            theme: store.theme
        )
        // 通常のiPhone画面に近い9:16で書き出し、Statsの相対サイズを揃える。
        .frame(width: 360, height: 780)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        renderer.isOpaque = true
        guard let image = renderer.uiImage else { return }
        // boolでシートを開くと、初回だけ画像がnilの古いクロージャを参照して
        // 空の画面になることがあるため、画像自身をpresentation itemにする。
        sharePayload = SharePayload(image: image)
    }

    @MainActor
    private func scheduleReviewIfNeeded() {
        guard scenePhase == .active, scheduledReviewTrigger == nil,
              let trigger = ReviewRequestPolicy.nextEligibleTrigger(
                activeDays: store.reviewEligibleActiveDays
              ) else { return }

        scheduledReviewTrigger = trigger
        reviewRequestTask?.cancel()
        reviewRequestTask = Task { @MainActor in
            do {
                // Give people time to view their recorded map, not a launch-time prompt.
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                scheduledReviewTrigger = nil
                return
            }
            guard !Task.isCancelled, scenePhase == .active,
                  !showsSettings, sharePayload == nil, datePickerTarget == nil,
                  selectedPlace == nil, !coursePlanner.isPresented, !showsCourseOriginSearch,
                  store.recorder.authorizationStatus != .notDetermined,
                  ReviewRequestPolicy.nextEligibleTrigger(activeDays: store.reviewEligibleActiveDays) == trigger else {
                scheduledReviewTrigger = nil
                return
            }
            requestReview()
            ReviewRequestPolicy.markRequested(trigger)
            scheduledReviewTrigger = nil
        }
    }
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct PeriodPicker: View {
    @Binding var selection: PeriodPreset
    let theme: AppTheme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(PeriodPreset.allCases) { period in
                Button {
                    withAnimation(.snappy) { selection = period }
                } label: {
                    Text(LocalizedStringKey(period.rawValue))
                        .font(.system(size: 13, weight: selection == period ? .semibold : .regular))
                        .foregroundStyle(
                            selection == period
                                ? theme.selectedControlForeground
                                : theme.foregroundColor.opacity(0.62)
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background {
                            if selection == period {
                                Capsule()
                                    .fill(theme.selectedControlBackground)
                                    .shadow(color: theme.shadowColor, radius: 5, y: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(maxWidth: 350)
        .background(theme.controlBackground, in: Capsule())
        .overlay(Capsule().stroke(theme.controlBorder, lineWidth: 1))
        .shadow(color: theme.shadowColor, radius: 16, y: 6)
    }
}

private struct RangeSlider: View {
    private enum ActiveHandle {
        case lower
        case upper
    }

    @Binding var lower: Double
    @Binding var upper: Double
    let color: Color
    @State private var activeHandle: ActiveHandle?

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width - 18)
            let lowerX = 9 + width * lower
            let upperX = 9 + width * upper
            let centerY = proxy.size.height / 2
            let dragGesture = DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if activeHandle == nil {
                        let lowerDistance = abs(value.startLocation.x - lowerX)
                        let upperDistance = abs(value.startLocation.x - upperX)
                        activeHandle = lowerDistance <= upperDistance ? .lower : .upper
                    }

                    let fraction = min(1, max(0, (value.location.x - 9) / width))
                    switch activeHandle {
                    case .lower:
                        lower = min(upper - 0.025, fraction)
                    case .upper:
                        upper = max(lower + 0.025, fraction)
                    case nil:
                        break
                    }
                }
                .onEnded { _ in
                    activeHandle = nil
                }

            ZStack(alignment: .leading) {
                // 見た目より大きい44ptの領域全体でドラッグを受け、
                // 背後のMapKitへジェスチャーが抜けないようにする。
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                Capsule().fill(Color.secondary.opacity(0.18)).frame(height: 3)
                    .padding(.horizontal, 9)
                Capsule().fill(color.opacity(0.88)).frame(width: max(1, upperX - lowerX), height: 3)
                    .offset(x: lowerX)
                handle(x: lowerX, y: centerY)
                handle(x: upperX, y: centerY)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(dragGesture)
        }
    }

    private func handle(x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 20, height: 20)
            .overlay(Circle().stroke(color, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.13), radius: 4, y: 2)
            .position(x: x, y: y)
    }
}

private enum DatePickerTarget: String, Identifiable {
    case start
    case end

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .start: "開始日"
        case .end: "終了日"
        }
    }
}

private struct RangeDatePickerSheet: View {
    let target: DatePickerTarget
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private var selection: Binding<Date> {
        Binding(
            get: {
                target == .start ? store.selectedDateRange.lowerBound : store.selectedDateRange.upperBound
            },
            set: { date in
                if target == .start {
                    store.setRangeStartDate(date)
                } else {
                    store.setRangeEndDate(date)
                }
            }
        )
    }

    private var allowedRange: ClosedRange<Date> {
        if target == .start {
            return store.baseDateRange.lowerBound...store.selectedDateRange.upperBound
        }
        return store.selectedDateRange.lowerBound...store.baseDateRange.upperBound
    }

    var body: some View {
        NavigationStack {
            DatePicker(target.title, selection: selection, in: allowedRange, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle(target.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

private struct PlaceInfoCard: View {
    let place: MapPlaceDetails
    let theme: AppTheme
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.interactionColor)
                    .frame(width: 34, height: 34)
                    .background(theme.interactionColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.foregroundColor)
                        .lineLimit(2)
                    if let address = place.address, !address.isEmpty {
                        Text(address)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(theme.foregroundColor.opacity(0.62))
                            .lineLimit(2)
                    } else if place.isLoading {
                        Text("詳細情報を読み込み中")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(theme.foregroundColor.opacity(0.55))
                    }
                }

                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.foregroundColor.opacity(0.64))
                        .frame(width: 30, height: 30)
                        .background(theme.foregroundColor.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("閉じる"))
            }

            if place.isLoading || place.phoneNumber != nil || place.website != nil {
                HStack(spacing: 16) {
                    if place.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if let phoneNumber = place.phoneNumber,
                       let url = URL(string: "tel:\(phoneNumber.filter { $0.isNumber || $0 == "+" })") {
                        Link(destination: url) {
                            Label("電話", systemImage: "phone.fill")
                        }
                    }
                    if let website = place.website {
                        Link(destination: website) {
                            Label("Webサイト", systemImage: "safari")
                        }
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .tint(theme.interactionColor)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.controlBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(theme.controlBorder, lineWidth: 1))
        .shadow(color: theme.shadowColor, radius: 18, y: 7)
    }
}

private struct FloatingButton: View {
    let icon: String
    let label: String
    let theme: AppTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 48, height: 48)
                .foregroundStyle(theme.prefersDarkMap ? theme.interactionColor : theme.foregroundColor.opacity(0.82))
                .background(theme.controlBackground, in: Circle())
                .overlay(Circle().stroke(theme.controlBorder, lineWidth: 1))
                .shadow(color: theme.shadowColor, radius: 10, y: 5)
        }
        .accessibilityLabel(label)
    }
}

private struct TransportFilterControl: View {
    let visibleModes: Set<TransportMode>
    let theme: AppTheme
    let onToggle: (TransportMode) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(TransportMode.allCases) { mode in
                let isVisible = visibleModes.contains(mode)
                Button {
                    withAnimation(.snappy) { onToggle(mode) }
                } label: {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 38, height: 36)
                        .foregroundStyle(
                            isVisible
                                ? theme.selectedControlForeground
                                : theme.foregroundColor.opacity(0.34)
                        )
                        .background {
                            if isVisible {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(theme.selectedControlBackground)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(mode.title)の経路")
                .accessibilityValue(isVisible ? "表示" : "非表示")
            }
        }
        .padding(4)
        .background(theme.controlBackground, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(theme.controlBorder, lineWidth: 1))
        .shadow(color: theme.shadowColor, radius: 10, y: 5)
    }
}

private struct EmptyRouteView: View {
    let theme: AppTheme
    let hasHistory: Bool

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "location.north.line")
                .font(.system(size: 30, weight: .light))
            Text(LocalizedStringKey(hasHistory ? "この期間のデータがありません" : "まだ通った道がありません"))
                .font(.system(size: 14, weight: .semibold))
            Text(LocalizedStringKey(hasHistory ? "期間または表示する移動手段を変更してください" : "記録をオンにして移動すると、ここに道が重なります"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(theme.foregroundColor)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(theme.controlBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(theme.controlBorder, lineWidth: 1))
        .allowsHitTesting(false)
    }
}

private struct VerticalStatsPanel: View, Animatable {
    private var newRoadsValue: Double
    private var distanceValue: Double
    private var activeDaysValue: Double
    let theme: AppTheme
    let revealPhase: Int

    init(stats: WalkStats, theme: AppTheme, revealPhase: Int) {
        newRoadsValue = Double(stats.newRoads)
        distanceValue = stats.distance
        activeDaysValue = Double(stats.activeDays)
        self.theme = theme
        self.revealPhase = revealPhase
    }

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get {
            AnimatablePair(
                newRoadsValue,
                AnimatablePair(distanceValue, activeDaysValue)
            )
        }
        set {
            newRoadsValue = newValue.first
            distanceValue = newValue.second.first
            activeDaysValue = newValue.second.second
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            item(label: "新しい道", value: "\(Int(newRoadsValue.rounded()))", unit: "本")
                .staggeredReveal(revealPhase, stage: 1)
            item(label: "移動距離", value: distanceText, unit: distanceValue < 1_000 ? "m" : "km")
                .staggeredReveal(revealPhase, stage: 2)
            item(label: "アクティブ日数", value: "\(Int(activeDaysValue.rounded()))", unit: "日")
                .staggeredReveal(revealPhase, stage: 3)
        }
        .foregroundStyle(theme.foregroundColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 15)
    }

    private var distanceText: String {
        if distanceValue < 1_000 { return "\(Int(distanceValue.rounded()))" }
        let km = distanceValue / 1_000
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
                    .contentTransition(.numericText())
                Text(LocalizedStringKey(unit)).font(.system(size: 13, weight: .medium))
            }
            Rectangle()
                .fill(theme.foregroundColor.opacity(0.26))
                .frame(width: 92, height: 0.75)
        }
        .shadow(color: theme.backgroundColor.opacity(0.88), radius: 3)
    }
}

private extension View {
    func staggeredReveal(_ phase: Int, stage: Int) -> some View {
        opacity(phase >= stage ? 1 : 0)
            .offset(y: phase >= stage ? 0 : 7)
            .allowsHitTesting(phase >= stage)
    }
}
