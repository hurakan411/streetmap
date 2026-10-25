import Combine
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
    @State private var isUIHidden = !UserDefaults.standard.bool(forKey: "mapGuide.completed.v1")
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
    @AppStorage("mapGuide.completed.v1") private var hasCompletedMapGuide = false
    @State private var guideStep: MapGuideStep? = UserDefaults.standard.bool(forKey: "mapGuide.completed.v1") ? nil : .reveal
    @State private var guideIsReady = false
    @State private var guideAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    @State private var guideContentOpacity = 0.0
    @State private var guideIsTransitioning = false
    @State private var guideTransitionTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    if guideStep == nil && !coursePlanner.isPresented { toggleUIVisibility() }
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
            .allowsHitTesting(guideStep == nil)

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
                                    .mapGuideTarget(.stats)
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
                                .mapGuideTarget(.settings)
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
                                .mapGuideTarget(.courses)
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
                                .mapGuideTarget(.mapMode)
                                .staggeredReveal(revealPhase, stage: 5)
                                FloatingButton(icon: "square.and.arrow.up", label: "共有", theme: store.theme) {
                                    requestShare()
                                }
                                .disabled(coursePlanner.isPresented)
                                .mapGuideTarget(.share)
                                .staggeredReveal(revealPhase, stage: 6)
                                FloatingButton(icon: "location.fill", label: "現在地", theme: store.theme) {
                                    if store.recorder.authorizationStatus == .notDetermined {
                                        store.recorder.requestForegroundAuthorization()
                                    }
                                    store.refreshCurrentLocation()
                                    recenterToken += 1
                                }
                                .mapGuideTarget(.location)
                                .staggeredReveal(revealPhase, stage: 7)
                                TransportFilterControl(
                                    visibleModes: store.visibleTransportModes,
                                    theme: store.theme,
                                    onToggle: store.toggleTransportMode
                                )
                                .mapGuideTarget(.transport)
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
        .accessibilityHidden(guideStep != nil)
        .overlayPreferenceValue(MapGuideAnchorKey.self) { anchors in
            GeometryReader { proxy in
                let insets = proxy.safeAreaInsets
                if let step = guideStep, guideIsReady {
                    MapGuideOverlay(step: step,
                        target: anchors[step].map { proxy[$0].offsetBy(dx: 0, dy: insets.top) },
                        safeInsets: insets,
                        contentOpacity: guideContentOpacity,
                        japanese: courseIsJapanese, onNext: advanceMapGuide,
                        onSkip: finishMapGuide)
                        // Expand only the guide layer. Keep anchors and the map's layout unchanged.
                        .frame(width: proxy.size.width, height: proxy.size.height + insets.top + insets.bottom)
                        .offset(y: -insets.top)
                } else if guideStep != nil {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { }
                }
            }
        }
        .onReceive(store.recorder.$authorizationStatus.receive(on: RunLoop.main)) { status in
            guideAuthorizationStatus = status
        }
        .task(id: "\(scenePhase)-\(guideAuthorizationStatus.rawValue)-\(showsSettings)-\(String(describing: guideStep))") {
            if guideStep == .reveal || scenePhase != .active || showsSettings { guideIsReady = false }
            guard guideStep != nil, scenePhase == .active, !showsSettings,
                  !store.showsWidgetRecordingSettings,
                  store.recordingMode == .off || guideAuthorizationStatus != .notDetermined else { return }
            // Let native permission sheets and the existing UI reveal finish first.
            do {
                try await Task.sleep(for: .milliseconds(guideStep == .reveal || guideStep == .stats ? 950 : 120))
                guard !Task.isCancelled else { return }
                guideIsReady = true
                if !guideIsTransitioning {
                    withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.12)) { guideContentOpacity = 1 }
                }
            } catch { }
        }
        .onReceive(NotificationCenter.default.publisher(for: .michiShowMapGuide)) { _ in
            showsSettings = false
            coursePlanner.close()
            selectedPlace = nil
            revealTask?.cancel()
            reviewRequestTask?.cancel()
            guideIsReady = false
            guideTransitionTask?.cancel()
            guideIsTransitioning = false
            guideContentOpacity = 0
            isUIHidden = true
            isHidingUI = false
            revealPhase = 0
            guideStep = .reveal
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
                guideTransitionTask?.cancel()
                guideIsTransitioning = false
                guideContentOpacity = 1
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
        .onDisappear {
            reviewRequestTask?.cancel()
            guideTransitionTask?.cancel()
        }
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
    private func advanceMapGuide() {
        guard let step = guideStep, !guideIsTransitioning else { return }
        if step == .reveal {
            guideIsReady = false
            guideContentOpacity = 0
            revealPhase = 0
            toggleUIVisibility()
            guideStep = .stats
            return
        }
        if reduceMotion {
            if let next = MapGuideStep(rawValue: step.rawValue + 1) { guideStep = next }
            else { finishMapGuide() }
            return
        }
        guideIsTransitioning = true
        guideTransitionTask = Task { @MainActor in
            defer { guideIsTransitioning = false }
            withAnimation(.easeOut(duration: 0.09)) { guideContentOpacity = 0 }
            do {
                try await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
                guard let next = MapGuideStep(rawValue: step.rawValue + 1) else {
                    finishMapGuide()
                    return
                }
                guideStep = next
                // Give the compact bubble one layout pass at its new location.
                try await Task.sleep(for: .milliseconds(20))
                withAnimation(.easeIn(duration: 0.12)) { guideContentOpacity = 1 }
                try await Task.sleep(for: .milliseconds(120))
            } catch { }
        }
    }

    private func finishMapGuide() {
        guideTransitionTask?.cancel()
        guideIsTransitioning = false
        revealTask?.cancel()
        hasCompletedMapGuide = true
        guideStep = nil
        guideIsReady = false
        isUIHidden = false
        isHidingUI = false
        revealPhase = 9
    }
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
        .mapGuideTarget(.period)
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
        guard guideStep == nil, hasCompletedMapGuide,
              scenePhase == .active, scheduledReviewTrigger == nil,
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
                  guideStep == nil,
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

private enum MapGuideStep: Int, CaseIterable {
    case reveal, stats, period, settings, courses, mapMode, share, location, transport, farewell

    func title(_ ja: Bool) -> String {
        switch self {
        case .reveal: ja ? "地図をタップしてみましょう。" : "Try tapping the map."
        case .stats: ja ? "散歩の記録を、ここで確認。" : "Your journeys at a glance."
        case .period: ja ? "見たい期間に絞れます。" : "Choose a time period."
        case .transport: ja ? "見たい移動だけを表示。" : "Show the journeys you want."
        case .mapMode: ja ? "地図の楽しみ方を変えてみよう。" : "See your map differently."
        case .courses: ja ? "次の散歩を探してみよう。" : "Find your next walk."
        case .share: ja ? "自分の地図を、一枚の画像に。" : "Share a map that is yours."
        case .location: ja ? "今いる場所へ戻れます。" : "Back to where you are."
        case .settings: ja ? "設定は、いつでもここから。" : "Make it your own."
        case .farewell: ja ? "それでは、楽しい散歩を！" : "Enjoy your next walk!"
        }
    }

    func detail(_ ja: Bool) -> String {
        switch self {
        case .reveal: ja ? "ボタンや散歩の記録が表示されます。\nもう一度タップすると隠せます。" : "Reveal your controls and journey stats.\nTap again to hide them."
        case .stats: ja ? "新しい道の数、移動距離、記録した日数が表示されます。" : "See new roads, distance travelled, and active days."
        case .period: ja ? "期間を切り替えたり、スライダーで調整できます。日付をタップして選ぶこともできます。" : "Choose a period, adjust the slider, or tap a date."
        case .transport: ja ? "表示する経路を切り替えます。記録する移動の設定は変わりません。" : "Filter the routes on your map without changing what gets recorded."
        case .mapMode: ja ? "通常の地図、開拓モード、経路だけの表示を切り替えられます。" : "Switch between the full map, Explore mode, and routes only."
        case .courses: ja ? "出発地や時間を選ぶと、まだ歩いていない道を中心にコースを提案します。" : "Choose a starting point and duration to find routes that favor streets you have not walked yet."
        case .share: ja ? "表示中の地図や経路を画像にして共有できます。" : "Turn the map and routes on screen into an image to share."
        case .location: ja ? "地図を動かしたあとも、このボタンで現在地を表示できます。" : "After moving around the map, tap here to return to your current location."
        case .settings: ja ? "記録方法や地図のデザインを変更できます。「アプリの使い方」でこの案内を見返せます。" : "Change recording and map styles. Replay this guide under How to use Street Print."
        case .farewell: ja ? "いつもの道にも、新しい発見が待っています。" : "Even familiar streets have something new to discover."
        }
    }
}

private struct MapGuideAnchorKey: PreferenceKey {
    static var defaultValue: [MapGuideStep: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [MapGuideStep: Anchor<CGRect>], nextValue: () -> [MapGuideStep: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func mapGuideTarget(_ step: MapGuideStep) -> some View {
        anchorPreference(key: MapGuideAnchorKey.self, value: .bounds) { [step: $0] }
    }
}

private struct MapGuideOverlay: View {
    let step: MapGuideStep
    let target: CGRect?
    let safeInsets: EdgeInsets
    let contentOpacity: Double
    let japanese: Bool
    let onNext: () -> Void
    let onSkip: () -> Void
    @AccessibilityFocusState private var focusesTitle: Bool
    @State private var cardHeight: CGFloat = 170

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let hole = target?.insetBy(dx: -5, dy: -5).intersection(bounds)
            let placement = cardPlacement(size: proxy.size, target: hole)
            ZStack {
                if step == .reveal {
                    Color.black.opacity(0.18)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onNext)
                        .accessibilityLabel(japanese ? "地図をタップしてUIを表示" : "Tap the map to show controls")
                        .accessibilityAddTraits(.isButton)
                } else {
                    Path { path in
                        path.addRect(bounds)
                        if let hole { path.addRoundedRect(in: hole, cornerSize: CGSize(width: 14, height: 14)) }
                    }
                    .fill(.black.opacity(0.54), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    if let hole {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(.black.opacity(0.54))
                            .frame(width: hole.width, height: hole.height)
                            .position(x: hole.midX, y: hole.midY)
                            .opacity(1 - contentOpacity)
                            .allowsHitTesting(false)
                    }
                    // The spotlight is visual only; controls never execute during the tour.
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(perform: onNext)
                        .accessibilityLabel(japanese
                            ? (step == .farewell ? "タップして案内を終了" : "タップして次の説明へ")
                            : (step == .farewell ? "Tap to finish the guide" : "Tap to continue the guide"))
                        .accessibilityAddTraits(.isButton)
                    if let hole {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(.white.opacity(0.94), lineWidth: 1.5)
                            .frame(width: hole.width, height: hole.height)
                            .position(x: hole.midX, y: hole.midY)
                            .opacity(contentOpacity)
                            .allowsHitTesting(false)
                    }
                }

                if let arrow = placement.arrow {
                    arrow.fill(Color(uiColor: .systemBackground))
                        .opacity(contentOpacity)
                        .allowsHitTesting(false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if step == .farewell {
                        Image(systemName: "figure.walk")
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(.blue)
                            .padding(.bottom, 6)
                    }
                    Text(step.title(japanese))
                        .font(.system(size: step == .farewell ? 20 : 16, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($focusesTitle)
                    Text(step.detail(japanese))
                        .font(.system(size: 12.5))
                        .lineSpacing(2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if step != .reveal {
                        HStack {
                            if step != .farewell { Text("\(step.rawValue) / 8")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(japanese
                                ? (step == .farewell ? "タップしてはじめる" : "タップして進む")
                                : (step == .farewell ? "Tap to start" : "Tap to continue"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(14)
                .frame(width: placement.width, alignment: .leading)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(Color.primary)
                .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { card in
                    Color.clear.preference(key: MapGuideCardHeightKey.self, value: card.size.height)
                })
                .position(placement.center)
                .opacity(contentOpacity)
                .allowsHitTesting(false)

                if step != .farewell { VStack {
                    HStack {
                        Spacer()
                        Button(japanese ? "スキップ" : "Skip", action: onSkip)
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 15).frame(minHeight: 44)
                            .foregroundStyle(.primary)
                            .background(.regularMaterial, in: Capsule())
                    }
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.top, safeInsets.top + 8)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .onPreferenceChange(MapGuideCardHeightKey.self) { if $0 > 0 { cardHeight = $0 } }
        .onChange(of: step, initial: true) { _, _ in focusesTitle = true }
    }

    private func cardPlacement(size: CGSize, target: CGRect?) -> (width: CGFloat, center: CGPoint, arrow: Path?) {
        let left = safeInsets.leading + 12, right = size.width - safeInsets.trailing - 12
        let top = safeInsets.top + 12, bottom = size.height - safeInsets.bottom - 12
        let height = max(60, cardHeight)
        func clampY(_ y: CGFloat) -> CGFloat { min(bottom - height / 2, max(top + height / 2, y)) }
        guard let target, step != .reveal else {
            return (min(276, right - left), CGPoint(x: size.width / 2, y: size.height * 0.46), nil)
        }
        let gap: CGFloat = 12
        let leftRoom = target.minX - gap - left
        let rightRoom = right - target.maxX - gap
        let width: CGFloat
        let center: CGPoint
        var arrow = Path()
        if leftRoom >= 190 {
            width = min(252, leftRoom)
            center = CGPoint(x: target.minX - gap - width / 2, y: clampY(target.midY))
            let y = min(center.y + height / 2 - 20, max(center.y - height / 2 + 20, target.midY))
            arrow.addLines([CGPoint(x: center.x + width / 2 - 1, y: y - 7),
                CGPoint(x: center.x + width / 2 + 8, y: y), CGPoint(x: center.x + width / 2 - 1, y: y + 7)])
        } else if rightRoom >= 190 {
            width = min(252, rightRoom)
            center = CGPoint(x: target.maxX + gap + width / 2, y: clampY(target.midY))
            let y = min(center.y + height / 2 - 20, max(center.y - height / 2 + 20, target.midY))
            arrow.addLines([CGPoint(x: center.x - width / 2 + 1, y: y - 7),
                CGPoint(x: center.x - width / 2 - 8, y: y), CGPoint(x: center.x - width / 2 + 1, y: y + 7)])
        } else {
            width = min(276, right - left)
            let above = target.minY - top >= height + gap
            center = CGPoint(x: min(right - width / 2, max(left + width / 2, target.midX)),
                y: clampY(above ? target.minY - gap - height / 2 : target.maxY + gap + height / 2))
            let x = min(center.x + width / 2 - 20, max(center.x - width / 2 + 20, target.midX))
            let edge = center.y + (above ? height / 2 : -height / 2)
            arrow.addLines([CGPoint(x: x - 7, y: edge), CGPoint(x: x, y: edge + (above ? 8 : -8)), CGPoint(x: x + 7, y: edge)])
        }
        arrow.closeSubpath()
        return (width, center, arrow)
    }
}

private struct MapGuideCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
