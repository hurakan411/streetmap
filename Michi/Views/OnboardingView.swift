import Combine
import CoreLocation
import CoreMotion
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var isComplete: Bool
    @State private var page = 0
    @State private var selectedRecordingMode: RecordingMode = .persistent
    @State private var selectedMovementMode: MovementCaptureMode = .all
    @State private var selectedTheme: AppTheme = .editorialGlass
    @State private var hasLoadedSelections = false
    @State private var isWaitingForAuthorization = false

    private let pageCount = 5

    var body: some View {
        ZStack {
            OnboardingBackdrop(page: page)

            VStack(spacing: 0) {
                header

                TabView(selection: $page) {
                    DiscoveryPage().tag(0)
                    RecordingPage().tag(1)
                    RecordingModeSelectionPage(selection: $selectedRecordingMode).tag(2)
                    MovementModeSelectionPage(selection: $selectedMovementMode).tag(3)
                    ThemeSelectionPage(selection: $selectedTheme).tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .disabled(isWaitingForAuthorization)

                footer
            }
        }
        .preferredColorScheme(.light)
        .animation(.snappy(duration: 0.42), value: page)
        .onAppear {
            guard !hasLoadedSelections else { return }
            selectedRecordingMode = store.recordingMode
            selectedMovementMode = store.movementCaptureMode
            selectedTheme = store.theme
            hasLoadedSelections = true
        }
        // Recorder is a nested ObservableObject: observe its publisher directly.
        // Deliver after @Published has committed the new authorization value.
        .onReceive(store.recorder.$authorizationStatus.receive(on: RunLoop.main)) { status in
            guard isWaitingForAuthorization else { return }
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                isWaitingForAuthorization = false
                finishOnboarding()
            } else if status == .denied || status == .restricted {
                isWaitingForAuthorization = false
                finishOnboarding(recordingModeOverride: .off)
            }
        }
    }

    private var header: some View {
            HStack {
            HStack(spacing: 10) {
                Image("BrandIcon")
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: pageAccent.opacity(0.18), radius: 4, y: 2)
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Street Print")
                        .font(.system(size: 18, weight: .bold))
                        .tracking(-0.45)
                    Text("Your Personal Route Map")
                        .font(.system(size: 7.5, weight: .semibold))
                        .tracking(0.35)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.black.opacity(0.42))
                }
                .foregroundStyle(Color(red: 0.08, green: 0.09, blue: 0.11))
            }

            Spacer()

            if page < 2 {
                Button("設定へ") {
                    withAnimation(.snappy) { page = 2 }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.46))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .frame(height: 54)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 7) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? pageAccent : Color.black.opacity(0.11))
                        .frame(width: index == page ? 22 : 6, height: 6)
                }
            }

            Button(action: primaryAction) {
                HStack(spacing: 9) {
                    Text(LocalizedStringKey(primaryButtonTitle))
                    Image(systemName: primaryButtonSymbol)
                        .font(.system(size: 13, weight: .bold))
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .foregroundStyle(.white)
                .background(Color(red: 0.075, green: 0.085, blue: 0.105), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isWaitingForAuthorization)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    private var pageAccent: Color {
        Color(red: 0.10, green: 0.32, blue: 0.98)
    }

    private var primaryButtonTitle: String {
        page == pageCount - 1 ? "続ける" : "次へ"
    }

    private var primaryButtonSymbol: String {
        "arrow.right"
    }

    private func primaryAction() {
        guard !isWaitingForAuthorization else { return }
        guard page == pageCount - 1 else {
            withAnimation(.snappy) { page += 1 }
            return
        }

        if selectedRecordingMode == .off {
            finishOnboarding()
            return
        }

        switch store.recorder.authorizationStatus {
        case .notDetermined:
            isWaitingForAuthorization = true
            store.recorder.requestForegroundAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            finishOnboarding()
        case .denied, .restricted:
            finishOnboarding(recordingModeOverride: .off)
        @unknown default:
            finishOnboarding(recordingModeOverride: .off)
        }
    }

    private func finishOnboarding(recordingModeOverride: RecordingMode? = nil) {
        store.theme = selectedTheme
        store.setMovementCaptureMode(selectedMovementMode)
        store.setRecordingMode(recordingModeOverride ?? selectedRecordingMode)
        ReviewRequestPolicy.markOnboardingCompleted()
        isComplete = true
    }
}

private struct OnboardingBackdrop: View {
    let page: Int

    var body: some View {
        Color(red: 0.965, green: 0.963, blue: 0.945)
        .ignoresSafeArea()
    }
}

private struct DiscoveryPage: View {
    var body: some View {
        OnboardingPageLayout(
            eyebrow: "歩いたぶんだけ、街がひらく",
            title: "歩くほど、\n街が自分の地図になる。",
            message: "通った道は色になり、まだ知らない道が見えてくる。\nいつもの散歩に、次の行き先を。"
        ) {
            EditorialCityArtwork()
        }
    }
}

private struct RecordingPage: View {
    var body: some View {
        OnboardingPageLayout(
            eyebrow: "使い方はシンプル",
            title: "ポケットに入れて、\n歩くだけ。",
            message: "アプリを閉じても移動を自動記録。\nあとで開けば、今日の道が残っています。"
        ) {
            AutoRecordArtwork()
        }
    }
}

private struct RecordingModeSelectionPage: View {
    @Binding var selection: RecordingMode

    var body: some View {
        OnboardingPageLayout(
            eyebrow: "STEP 1 · 記録タイミング",
            title: "いつ記録する？",
            message: "使い方に合うものを選んでください。\nあとから設定で変更できます。"
        ) {
            VStack(spacing: 8) {
                ForEach(RecordingMode.allCases) { mode in
                    OnboardingChoiceRow(
                        symbol: mode.symbol,
                        title: mode.title,
                        detail: mode.detail,
                        isSelected: selection == mode
                    ) {
                        withAnimation(.snappy(duration: 0.25)) { selection = mode }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
    }
}

private struct MovementModeSelectionPage: View {
    @Binding var selection: MovementCaptureMode

    var body: some View {
        OnboardingPageLayout(
            eyebrow: "STEP 2 · 記録する移動",
            title: "どこまで残す？",
            message: "速度をもとに記録対象を絞ります。\n散歩中心なら「徒歩のみ」がおすすめです。"
        ) {
            VStack(spacing: 8) {
                ForEach(MovementCaptureMode.allCases) { mode in
                    OnboardingChoiceRow(
                        symbol: mode.symbol,
                        title: mode.title,
                        detail: mode.detail,
                        isSelected: selection == mode
                    ) {
                        withAnimation(.snappy(duration: 0.25)) { selection = mode }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
    }
}

private struct ThemeSelectionPage: View {
    @Binding var selection: AppTheme
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 9), count: 3)

    var body: some View {
        OnboardingPageLayout(
            eyebrow: "STEP 3 · デザイン",
            title: "好きな地図で、\n始めよう。",
            message: "経路や地図の色を選べます。\nテンプレートはいつでも変更できます。"
        ) {
            LazyVGrid(columns: columns, spacing: 9) {
                ForEach(AppTheme.allCases) { theme in
                    OnboardingThemeCard(
                        theme: theme,
                        isSelected: selection == theme
                    ) {
                        withAnimation(.snappy(duration: 0.25)) { selection = theme }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 7)
        }
    }
}

private struct OnboardingChoiceRow: View {
    let symbol: String
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : OnboardingPalette.mutedInk)
                    .frame(width: 36, height: 36)
                    .background(isSelected ? OnboardingPalette.blue : Color.black.opacity(0.045), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OnboardingPalette.ink)
                    Text(LocalizedStringKey(detail))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(OnboardingPalette.mutedInk)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(isSelected ? OnboardingPalette.blue : Color.black.opacity(0.13))
            }
            .padding(.horizontal, 14)
            .frame(height: 76)
            .background(OnboardingPalette.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(isSelected ? OnboardingPalette.blue : Color.black.opacity(0.065), lineWidth: isSelected ? 1.8 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct OnboardingThemeCard: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(theme.backgroundColor)

                    OnboardingRouteShape()
                        .stroke(
                            theme.routeColor,
                            style: StrokeStyle(lineWidth: 2.2 * theme.lineScale, lineCap: .round, lineJoin: .round)
                        )
                        .padding(10)

                    if isSelected {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .black))
                                    .foregroundStyle(theme.selectedControlForeground)
                                    .frame(width: 21, height: 21)
                                    .background(theme.selectedControlBackground, in: Circle())
                            }
                            Spacer()
                        }
                        .padding(7)
                    }
                }
                .frame(height: 76)

                Text(LocalizedStringKey(theme.name))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.ink)
                    .lineLimit(1)
            }
            .padding(7)
            .background(OnboardingPalette.white, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .stroke(isSelected ? OnboardingPalette.blue : Color.black.opacity(0.065), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct OnboardingRouteShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY * 0.78))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.25),
            control1: CGPoint(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.20),
            control2: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.maxY * 0.92)
        )
        return path
    }
}

private struct PermissionPage: View {
    @ObservedObject var recorder: LocationRecorder

    var body: some View {
        OnboardingPageLayout(
            eyebrow: "記録はあなた次第",
            title: "記録方法を、\n自分に合わせて。",
            message: "常時記録・アプリ起動中のみ・オフ。\nいつでも設定から切り替えられます。"
        ) {
            RecordingSettingsArtwork(
                locationState: locationState,
                locationDetail: locationDetail,
                motionState: motionState,
                motionDetail: motionDetail
            )
        }
    }

    private var locationState: PermissionVisualState {
        switch recorder.authorizationStatus {
        case .authorizedAlways: .complete
        case .authorizedWhenInUse: .attention
        case .denied, .restricted: .denied
        default: .pending
        }
    }

    private var locationDetail: String {
        switch recorder.authorizationStatus {
        case .authorizedAlways: "常時記録を利用できます"
        case .authorizedWhenInUse: "次に「常に許可」を設定します"
        case .denied: "iPhoneの設定で許可してください"
        case .restricted: "この端末では位置情報を利用できません"
        default: "経路を記録するために使用"
        }
    }

    private var motionState: PermissionVisualState {
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: .complete
        case .denied, .restricted: .denied
        case .notDetermined: .pending
        @unknown default: .pending
        }
    }

    private var motionDetail: String {
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: "移動手段を判定できます"
        case .denied, .restricted: "速度から移動手段を推定します"
        case .notDetermined: "記録開始時に確認します"
        @unknown default: "記録開始時に確認します"
        }
    }
}

private enum OnboardingPalette {
    static let ink = Color(red: 0.075, green: 0.085, blue: 0.105)
    static let mutedInk = Color(red: 0.36, green: 0.37, blue: 0.39)
    static let blue = Color(red: 0.10, green: 0.32, blue: 0.98)
    static let map = Color(red: 0.91, green: 0.92, blue: 0.89)
    static let road = Color(red: 0.62, green: 0.64, blue: 0.61)
    static let white = Color(red: 0.995, green: 0.995, blue: 0.985)
}

/// 1枚目は、街が現れ、通った道が育ち、未踏の道が残るまでを一つの短い物語にする。
private struct EditorialCityArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { timeline in
            let phase = reduceMotion
                ? CGFloat(0.84)
                : CGFloat(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6.6) / 6.6)
            let mapReveal = reduceMotion ? CGFloat(1) : smooth(clamp(phase / 0.11))
            let routeProgress = reduceMotion ? CGFloat(1) : smooth(clamp((phase - 0.08) / 0.61))
            let discoveryProgress = reduceMotion ? CGFloat(1) : smooth(clamp((phase - 0.69) / 0.15))
            let loopOpacity = reduceMotion || phase < 0.92 ? CGFloat(1) : smooth(clamp((1 - phase) / 0.08))
            let roadsDrawn = min(
                visitedRoadIndices.count,
                max(0, Int(ceil(routeProgress * CGFloat(visitedRoadIndices.count))))
            )

            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color(red: 0.94, green: 0.93, blue: 0.89))
                    .shadow(color: OnboardingPalette.ink.opacity(0.09), radius: 22, y: 12)

                Canvas { context, size in
                    drawMap(
                        in: &context,
                        size: size,
                        routeProgress: routeProgress,
                        discoveryProgress: discoveryProgress,
                        phase: phase
                    )
                }

                VStack(spacing: 0) {
                    HStack(alignment: .center) {
                        Text("STREET PRINT")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1.25)

                        Spacer()

                        HStack(spacing: 5) {
                            Circle()
                                .fill(OnboardingPalette.blue)
                                .frame(width: 6, height: 6)
                            Text("\(roadsDrawn)")
                                .contentTransition(.numericText())
                                .monospacedDigit()
                            Text(LocalizedStringKey("歩いた道"))
                        }
                        .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(OnboardingPalette.ink.opacity(0.72))
                    .padding(.horizontal, 17)
                    .padding(.top, 15)

                    Spacer()

                    HStack(spacing: 16) {
                        MapLegend(color: OnboardingPalette.blue, title: "通った道")
                        MapLegend(
                            color: Color(red: 0.92, green: 0.31, blue: 0.24),
                            title: "まだの道",
                            opacity: discoveryProgress
                        )
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 17)
                    .padding(.bottom, 14)
                }
            }
            .scaleEffect(0.975 + 0.025 * mapReveal)
            .opacity(mapReveal * loopOpacity)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.72), lineWidth: 1)
                    .opacity(mapReveal)
            }
        }
        .padding(.horizontal, 1)
        .padding(.vertical, 7)
    }

    private struct MapLegend: View {
        let color: Color
        let title: String
        var opacity: CGFloat = 1

        var body: some View {
            HStack(spacing: 6) {
                Capsule()
                    .fill(color)
                    .frame(width: 17, height: 3)
                Text(LocalizedStringKey(title))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.ink.opacity(0.64))
            }
            .opacity(opacity)
        }
    }

    private func drawMap(
        in context: inout GraphicsContext,
        size: CGSize,
        routeProgress: CGFloat,
        discoveryProgress: CGFloat,
        phase: CGFloat
    ) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Color(red: 0.94, green: 0.93, blue: 0.89))
        )

        // 川と緑地だけを面で置き、情報量を増やしても経路の邪魔をしない地図にする。
        var river = Path()
        river.move(to: point(0.95, -0.06, size))
        river.addCurve(
            to: point(0.86, 1.07, size),
            control1: point(0.74, 0.26, size),
            control2: point(1.05, 0.63, size)
        )
        context.stroke(
            river,
            with: .color(Color(red: 0.61, green: 0.80, blue: 0.90).opacity(0.72)),
            style: StrokeStyle(lineWidth: 28, lineCap: .round)
        )

        context.fill(
            Path(roundedRect: CGRect(x: size.width * 0.07, y: size.height * 0.28, width: size.width * 0.18, height: size.height * 0.22), cornerRadius: 18),
            with: .color(Color(red: 0.73, green: 0.82, blue: 0.64).opacity(0.70))
        )
        context.fill(
            Path(roundedRect: CGRect(x: size.width * 0.57, y: size.height * 0.58, width: size.width * 0.16, height: size.height * 0.20), cornerRadius: 16),
            with: .color(Color(red: 0.73, green: 0.82, blue: 0.64).opacity(0.62))
        )

        for street in localStreets {
            context.stroke(
                mapPath(street, size: size),
                with: .color(Color.white.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
            )
        }

        for road in arterialRoads {
            let path = mapPath(road, size: size)
            context.stroke(
                path,
                with: .color(Color.white.opacity(0.92)),
                style: StrokeStyle(lineWidth: 6.2, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                path,
                with: .color(Color(red: 0.70, green: 0.68, blue: 0.63).opacity(0.46)),
                style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round)
            )
        }

        // 経路間に待ち時間を置かず、常にどこかの道が伸び続ける。
        let scaledProgress = routeProgress * CGFloat(visitedRoadIndices.count)
        for (order, roadIndex) in visitedRoadIndices.enumerated() {
            let localProgress = clamp(scaledProgress - CGFloat(order))
            guard localProgress > 0 else { continue }
            let routePath = mapPath(arterialRoads[roadIndex], size: size)
                .trimmedPath(from: 0, to: localProgress)

            context.stroke(
                routePath,
                with: .color(Color.white.opacity(0.88)),
                style: StrokeStyle(lineWidth: 7.0, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                routePath,
                with: .color(OnboardingPalette.blue),
                style: StrokeStyle(lineWidth: 4.2, lineCap: .round, lineJoin: .round)
            )
        }

        drawRouteHead(in: &context, size: size, scaledProgress: scaledProgress)

        let pulse = reduceMotion ? CGFloat(1) : CGFloat(0.78 + 0.22 * sin(Double(phase) * .pi * 16))
        for roadIndex in unvisitedRoadIndices {
            let path = mapPath(arterialRoads[roadIndex], size: size)
            context.stroke(
                path,
                with: .color(Color(red: 0.92, green: 0.31, blue: 0.24).opacity(0.72 * discoveryProgress * pulse)),
                style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round, dash: [3, 6])
            )
        }
    }

    private func drawRouteHead(in context: inout GraphicsContext, size: CGSize, scaledProgress: CGFloat) {
        guard scaledProgress > 0, scaledProgress < CGFloat(visitedRoadIndices.count) else { return }
        let order = min(Int(scaledProgress), visitedRoadIndices.count - 1)
        let localProgress = clamp(scaledProgress - CGFloat(order))
        let headOpacity = min(1, localProgress * 10) * min(1, (1 - localProgress) * 10)
        let center = interpolatedPoint(
            on: arterialRoads[visitedRoadIndices[order]],
            progress: localProgress,
            size: size
        )
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)),
            with: .color(Color.white.opacity(0.96 * headOpacity))
        )
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)),
            with: .color(OnboardingPalette.blue.opacity(headOpacity))
        )
    }

    private let visitedRoadIndices = [3, 0, 4, 2, 6, 8]
    private let unvisitedRoadIndices = [1, 5, 7]

    private var arterialRoads: [[CGPoint]] {
        [
            [CGPoint(x: -0.04, y: 0.20), CGPoint(x: 0.18, y: 0.20), CGPoint(x: 0.48, y: 0.20), CGPoint(x: 0.78, y: 0.20), CGPoint(x: 1.04, y: 0.20)],
            [CGPoint(x: -0.04, y: 0.45), CGPoint(x: 0.18, y: 0.45), CGPoint(x: 0.48, y: 0.45), CGPoint(x: 0.78, y: 0.45), CGPoint(x: 1.04, y: 0.45)],
            [CGPoint(x: -0.04, y: 0.72), CGPoint(x: 0.18, y: 0.72), CGPoint(x: 0.48, y: 0.72), CGPoint(x: 0.78, y: 0.72), CGPoint(x: 1.04, y: 0.72)],
            [CGPoint(x: 0.18, y: -0.05), CGPoint(x: 0.18, y: 0.20), CGPoint(x: 0.18, y: 0.45), CGPoint(x: 0.18, y: 0.72), CGPoint(x: 0.18, y: 1.05)],
            [CGPoint(x: 0.48, y: -0.05), CGPoint(x: 0.48, y: 0.20), CGPoint(x: 0.48, y: 0.45), CGPoint(x: 0.48, y: 0.72), CGPoint(x: 0.48, y: 1.05)],
            [CGPoint(x: 0.78, y: -0.05), CGPoint(x: 0.78, y: 0.20), CGPoint(x: 0.78, y: 0.45), CGPoint(x: 0.78, y: 0.72), CGPoint(x: 0.78, y: 1.05)],
            [CGPoint(x: 0.02, y: 0.92), CGPoint(x: 0.18, y: 0.72), CGPoint(x: 0.48, y: 0.45), CGPoint(x: 0.78, y: 0.20), CGPoint(x: 0.96, y: 0.08)],
            [CGPoint(x: 0.03, y: 0.08), CGPoint(x: 0.18, y: 0.20), CGPoint(x: 0.48, y: 0.45), CGPoint(x: 0.78, y: 0.72), CGPoint(x: 0.96, y: 0.91)],
            [CGPoint(x: 0.04, y: 0.58), CGPoint(x: 0.18, y: 0.45), CGPoint(x: 0.48, y: 0.45), CGPoint(x: 0.78, y: 0.45), CGPoint(x: 0.94, y: 0.34)]
        ]
    }

    private var localStreets: [[CGPoint]] {
        [
            [CGPoint(x: 0.03, y: 0.10), CGPoint(x: 0.10, y: 0.13), CGPoint(x: 0.18, y: 0.12)],
            [CGPoint(x: 0.29, y: 0.05), CGPoint(x: 0.31, y: 0.20), CGPoint(x: 0.29, y: 0.34)],
            [CGPoint(x: 0.58, y: 0.06), CGPoint(x: 0.61, y: 0.20), CGPoint(x: 0.59, y: 0.35)],
            [CGPoint(x: 0.82, y: 0.09), CGPoint(x: 0.90, y: 0.12), CGPoint(x: 0.98, y: 0.10)],
            [CGPoint(x: 0.04, y: 0.33), CGPoint(x: 0.18, y: 0.34), CGPoint(x: 0.33, y: 0.32)],
            [CGPoint(x: 0.36, y: 0.28), CGPoint(x: 0.38, y: 0.45), CGPoint(x: 0.36, y: 0.62)],
            [CGPoint(x: 0.57, y: 0.30), CGPoint(x: 0.66, y: 0.32), CGPoint(x: 0.78, y: 0.30)],
            [CGPoint(x: 0.03, y: 0.84), CGPoint(x: 0.18, y: 0.86), CGPoint(x: 0.34, y: 0.84)],
            [CGPoint(x: 0.57, y: 0.86), CGPoint(x: 0.65, y: 0.72), CGPoint(x: 0.74, y: 0.85)],
            [CGPoint(x: 0.27, y: 0.58), CGPoint(x: 0.36, y: 0.56), CGPoint(x: 0.48, y: 0.59)],
            [CGPoint(x: 0.78, y: 0.57), CGPoint(x: 0.89, y: 0.59), CGPoint(x: 0.98, y: 0.56)]
        ]
    }

    private func mapPath(_ points: [CGPoint], size: CGSize) -> Path {
        var path = Path()
        path.addLines(points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
        return path
    }

    private func interpolatedPoint(on points: [CGPoint], progress: CGFloat, size: CGSize) -> CGPoint {
        guard points.count > 1 else {
            return points.first.map { point($0.x, $0.y, size) } ?? .zero
        }

        let mapped = points.map { point($0.x, $0.y, size) }
        let lengths = zip(mapped, mapped.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        var remaining = total * clamp(progress)

        for index in lengths.indices {
            let length = lengths[index]
            if remaining <= length || index == lengths.count - 1 {
                let amount = length > 0 ? remaining / length : 0
                return CGPoint(
                    x: mapped[index].x + (mapped[index + 1].x - mapped[index].x) * amount,
                    y: mapped[index].y + (mapped[index + 1].y - mapped[index].y) * amount
                )
            }
            remaining -= length
        }
        return mapped.last ?? .zero
    }

    private func point(_ x: CGFloat, _ y: CGFloat, _ size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }

    private func smooth(_ value: CGFloat) -> CGFloat {
        let value = clamp(value)
        return value * value * (3 - 2 * value)
    }
}

/// 旧案を残す必要はないが、既存プレビューの参照を安全に保つため別名で隔離する。
private struct LegacyEditorialCityArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { timeline in
            let phase = reduceMotion ? CGFloat(1) : CGFloat(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5.4) / 5.4)
            let progress = min(1, phase / 0.74)

            GeometryReader { proxy in
                ZStack(alignment: .bottomLeading) {
                    Canvas { context, size in
                        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.90, green: 0.93, blue: 0.88)))

                        // 公園と川を面で描き、単なる線図ではなく街の地図にする。
                        context.fill(
                            Path(roundedRect: CGRect(x: size.width * 0.07, y: size.height * 0.09, width: size.width * 0.22, height: size.height * 0.20), cornerRadius: 18),
                            with: .color(Color(red: 0.71, green: 0.82, blue: 0.66).opacity(0.74))
                        )
                        context.fill(
                            Path(roundedRect: CGRect(x: size.width * 0.53, y: size.height * 0.66, width: size.width * 0.19, height: size.height * 0.18), cornerRadius: 16),
                            with: .color(Color(red: 0.71, green: 0.82, blue: 0.66).opacity(0.74))
                        )

                        var river = Path()
                        river.move(to: CGPoint(x: size.width * 0.94, y: -20))
                        river.addCurve(
                            to: CGPoint(x: size.width * 0.76, y: size.height + 20),
                            control1: CGPoint(x: size.width * 0.75, y: size.height * 0.24),
                            control2: CGPoint(x: size.width * 1.04, y: size.height * 0.68)
                        )
                        context.stroke(river, with: .color(Color(red: 0.56, green: 0.76, blue: 0.90).opacity(0.8)), lineWidth: 18)

                        // 建物の輪郭を重ねて、道だけではない「暮らしのある街」の密度を作る。
                        for normalized in buildingFootprints {
                            // 道路の中心線だけでなく、建物の周囲にも余白を持たせる。
                            // これで道路が建物を貫通する見た目を避ける。
                            guard isBuildable(normalized) else { continue }
                            let rect = CGRect(
                                x: normalized.minX * size.width,
                                y: normalized.minY * size.height,
                                width: normalized.width * size.width,
                                height: normalized.height * size.height
                            )
                            let shadow = rect.offsetBy(dx: 1.8, dy: 2.2)
                            context.fill(
                                Path(roundedRect: shadow, cornerRadius: 2.5),
                                with: .color(Color(red: 0.49, green: 0.51, blue: 0.48).opacity(0.18))
                            )
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: 2.5),
                                with: .color(Color(red: 0.77, green: 0.78, blue: 0.73).opacity(0.92))
                            )
                            context.stroke(
                                Path(roundedRect: rect, cornerRadius: 2.5),
                                with: .color(Color.white.opacity(0.62)),
                                lineWidth: 0.7
                            )
                        }

                        for road in sideStreets {
                            context.stroke(
                                path(for: road, size: size),
                                with: .color(Color.white.opacity(0.75)),
                                style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
                            )
                        }

                        for road in cityRoads {
                            context.stroke(
                                path(for: road, size: size),
                                with: .color(Color.white.opacity(0.95)),
                                style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)
                            )
                        }

                        for (index, roadIndex) in visitedRoads.enumerated() {
                            let local = min(1, max(0, (progress - CGFloat(index) * 0.072) * 2.05))
                            guard local > 0 else { continue }
                            context.stroke(
                                path(for: cityRoads[roadIndex], size: size).trimmedPath(from: 0, to: local),
                                with: .color(OnboardingPalette.blue),
                                style: StrokeStyle(lineWidth: 4.4, lineCap: .round, lineJoin: .round)
                            )
                        }

                        context.draw(
                            Text("CENTRAL PARK")
                                .font(.system(size: 7, weight: .bold))
                                .tracking(0.9)
                                .foregroundStyle(Color(red: 0.30, green: 0.43, blue: 0.27).opacity(0.76)),
                            at: CGPoint(x: size.width * 0.18, y: size.height * 0.19)
                        )
                        context.draw(
                            Text("RIVER WALK")
                                .font(.system(size: 7, weight: .bold))
                                .tracking(0.9)
                                .foregroundStyle(Color(red: 0.31, green: 0.54, blue: 0.70).opacity(0.78)),
                            at: CGPoint(x: size.width * 0.83, y: size.height * 0.58)
                        )
                    }

                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(OnboardingPalette.blue)
                            .frame(width: 24, height: 3)
                        Text("歩いた道")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(OnboardingPalette.ink)
                        Spacer()
                        Text("YOUR WALK MAP")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1.3)
                            .foregroundStyle(OnboardingPalette.mutedInk)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(OnboardingPalette.white.opacity(0.94))
                }
            }
        }
        .padding(.horizontal, -24)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private let visitedRoads = [0, 2, 3, 5, 7, 8, 10, 12]

    private var cityRoads: [[CGPoint]] {
        [
            [CGPoint(x: -0.05, y: 0.17), CGPoint(x: 0.22, y: 0.25), CGPoint(x: 0.55, y: 0.16), CGPoint(x: 1.05, y: 0.28)],
            [CGPoint(x: -0.04, y: 0.40), CGPoint(x: 0.29, y: 0.36), CGPoint(x: 0.66, y: 0.45), CGPoint(x: 1.04, y: 0.38)],
            [CGPoint(x: -0.04, y: 0.63), CGPoint(x: 0.29, y: 0.55), CGPoint(x: 0.67, y: 0.69), CGPoint(x: 1.05, y: 0.59)],
            [CGPoint(x: -0.04, y: 0.84), CGPoint(x: 0.31, y: 0.76), CGPoint(x: 0.62, y: 0.86), CGPoint(x: 1.05, y: 0.76)],
            [CGPoint(x: 0.13, y: -0.05), CGPoint(x: 0.22, y: 0.29), CGPoint(x: 0.16, y: 1.05)],
            [CGPoint(x: 0.36, y: -0.05), CGPoint(x: 0.34, y: 0.34), CGPoint(x: 0.40, y: 1.05)],
            [CGPoint(x: 0.59, y: -0.05), CGPoint(x: 0.54, y: 0.31), CGPoint(x: 0.61, y: 1.05)],
            [CGPoint(x: 0.83, y: -0.05), CGPoint(x: 0.73, y: 0.35), CGPoint(x: 0.86, y: 1.05)],
            [CGPoint(x: 0.01, y: 0.94), CGPoint(x: 0.26, y: 0.56), CGPoint(x: 0.49, y: 0.34), CGPoint(x: 0.93, y: 0.04)],
            [CGPoint(x: 0.03, y: 0.05), CGPoint(x: 0.31, y: 0.24), CGPoint(x: 0.63, y: 0.55), CGPoint(x: 0.98, y: 0.96)],
            [CGPoint(x: 0.04, y: 0.52), CGPoint(x: 0.26, y: 0.43), CGPoint(x: 0.56, y: 0.59), CGPoint(x: 0.96, y: 0.47)],
            [CGPoint(x: 0.34, y: 0.03), CGPoint(x: 0.35, y: 0.28), CGPoint(x: 0.56, y: 0.72), CGPoint(x: 0.67, y: 0.98)],
            [CGPoint(x: 0.65, y: 0.02), CGPoint(x: 0.56, y: 0.26), CGPoint(x: 0.30, y: 0.74), CGPoint(x: 0.18, y: 0.98)],
            [CGPoint(x: 0.94, y: 0.05), CGPoint(x: 0.73, y: 0.23), CGPoint(x: 0.47, y: 0.43), CGPoint(x: 0.08, y: 0.61)]
        ]
    }

    private var sideStreets: [[CGPoint]] {
        [
            [CGPoint(x: 0.02, y: 0.07), CGPoint(x: 0.20, y: 0.13), CGPoint(x: 0.35, y: 0.08)],
            [CGPoint(x: 0.28, y: 0.05), CGPoint(x: 0.30, y: 0.18), CGPoint(x: 0.27, y: 0.30)],
            [CGPoint(x: 0.54, y: 0.05), CGPoint(x: 0.62, y: 0.12), CGPoint(x: 0.60, y: 0.29)],
            [CGPoint(x: 0.72, y: 0.12), CGPoint(x: 0.88, y: 0.18), CGPoint(x: 1.00, y: 0.12)],
            [CGPoint(x: 0.03, y: 0.30), CGPoint(x: 0.16, y: 0.34), CGPoint(x: 0.29, y: 0.31)],
            [CGPoint(x: 0.37, y: 0.25), CGPoint(x: 0.43, y: 0.39), CGPoint(x: 0.40, y: 0.49)],
            [CGPoint(x: 0.69, y: 0.27), CGPoint(x: 0.80, y: 0.35), CGPoint(x: 0.98, y: 0.32)],
            [CGPoint(x: 0.03, y: 0.52), CGPoint(x: 0.18, y: 0.58), CGPoint(x: 0.30, y: 0.54)],
            [CGPoint(x: 0.38, y: 0.57), CGPoint(x: 0.43, y: 0.66), CGPoint(x: 0.40, y: 0.79)],
            [CGPoint(x: 0.61, y: 0.50), CGPoint(x: 0.76, y: 0.56), CGPoint(x: 0.96, y: 0.53)],
            [CGPoint(x: 0.05, y: 0.78), CGPoint(x: 0.19, y: 0.84), CGPoint(x: 0.35, y: 0.80)],
            [CGPoint(x: 0.51, y: 0.85), CGPoint(x: 0.59, y: 0.74), CGPoint(x: 0.71, y: 0.86)],
            [CGPoint(x: 0.78, y: 0.74), CGPoint(x: 0.87, y: 0.82), CGPoint(x: 0.99, y: 0.79)]
        ]
    }

    private var buildingFootprints: [CGRect] {
        [
            CGRect(x: 0.03, y: 0.32, width: 0.055, height: 0.065), CGRect(x: 0.10, y: 0.34, width: 0.065, height: 0.045),
            CGRect(x: 0.19, y: 0.31, width: 0.050, height: 0.070), CGRect(x: 0.30, y: 0.10, width: 0.060, height: 0.055),
            CGRect(x: 0.38, y: 0.09, width: 0.095, height: 0.060), CGRect(x: 0.49, y: 0.08, width: 0.045, height: 0.075),
            CGRect(x: 0.65, y: 0.08, width: 0.060, height: 0.070), CGRect(x: 0.72, y: 0.13, width: 0.055, height: 0.060),
            CGRect(x: 0.33, y: 0.27, width: 0.055, height: 0.075), CGRect(x: 0.43, y: 0.29, width: 0.085, height: 0.050),
            CGRect(x: 0.55, y: 0.28, width: 0.060, height: 0.065), CGRect(x: 0.65, y: 0.29, width: 0.045, height: 0.070),
            CGRect(x: 0.77, y: 0.30, width: 0.060, height: 0.055), CGRect(x: 0.86, y: 0.31, width: 0.055, height: 0.070),
            CGRect(x: 0.05, y: 0.48, width: 0.060, height: 0.055), CGRect(x: 0.14, y: 0.47, width: 0.070, height: 0.065),
            CGRect(x: 0.25, y: 0.48, width: 0.055, height: 0.055), CGRect(x: 0.35, y: 0.50, width: 0.070, height: 0.065),
            CGRect(x: 0.47, y: 0.51, width: 0.055, height: 0.050), CGRect(x: 0.58, y: 0.50, width: 0.065, height: 0.070),
            CGRect(x: 0.67, y: 0.52, width: 0.050, height: 0.055), CGRect(x: 0.06, y: 0.70, width: 0.070, height: 0.060),
            CGRect(x: 0.17, y: 0.69, width: 0.050, height: 0.070), CGRect(x: 0.28, y: 0.69, width: 0.075, height: 0.055),
            CGRect(x: 0.37, y: 0.72, width: 0.055, height: 0.065), CGRect(x: 0.75, y: 0.68, width: 0.060, height: 0.060),
            CGRect(x: 0.84, y: 0.70, width: 0.055, height: 0.070), CGRect(x: 0.09, y: 0.86, width: 0.065, height: 0.055),
            CGRect(x: 0.27, y: 0.84, width: 0.060, height: 0.065), CGRect(x: 0.42, y: 0.87, width: 0.070, height: 0.050),
            CGRect(x: 0.65, y: 0.86, width: 0.055, height: 0.060), CGRect(x: 0.76, y: 0.87, width: 0.065, height: 0.055)
        ]
    }

    private func isBuildable(_ footprint: CGRect) -> Bool {
        let clearance = footprint.insetBy(dx: -0.014, dy: -0.020)
        return !(cityRoads + sideStreets).contains { road in
            roadIntersects(clearance, road: road)
        }
    }

    private func roadIntersects(_ rect: CGRect, road: [CGPoint]) -> Bool {
        for (start, end) in zip(road, road.dropFirst()) {
            // 直線区間を細かくサンプリングして、街区の余白まで侵入していないか確認する。
            for step in 0...18 {
                let t = CGFloat(step) / 18
                let point = CGPoint(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t
                )
                if rect.contains(point) { return true }
            }
        }
        return false
    }

    private func path(for road: [CGPoint], size: CGSize) -> Path {
        var path = Path()
        path.addLines(road.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
        return path
    }
}

/// 1枚目と同じ地図タイルを使い、2枚目では「持ち歩くだけで記録される」を見せる。
private struct AutoRecordArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { timeline in
            let phase = reduceMotion
                ? CGFloat(0.84)
                : CGFloat(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6.6) / 6.6)
            let mapReveal = reduceMotion ? CGFloat(1) : smooth(clamp(phase / 0.11))
            let progress = reduceMotion ? CGFloat(1) : smooth(clamp((phase - 0.08) / 0.61))
            let loopOpacity = reduceMotion || phase < 0.92 ? CGFloat(1) : smooth(clamp((1 - phase) / 0.08))

            GeometryReader { _ in
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color(red: 0.94, green: 0.93, blue: 0.89))
                        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.72), lineWidth: 1))
                        .shadow(color: OnboardingPalette.ink.opacity(0.09), radius: 22, y: 12)

                    Canvas { context, size in
                        context.fill(
                            Path(CGRect(origin: .zero, size: size)),
                            with: .color(Color(red: 0.94, green: 0.93, blue: 0.89))
                        )

                        var river = Path()
                        river.move(to: CGPoint(x: size.width * 0.95, y: -8))
                        river.addCurve(
                            to: CGPoint(x: size.width * 0.86, y: size.height + 8),
                            control1: CGPoint(x: size.width * 0.74, y: size.height * 0.25),
                            control2: CGPoint(x: size.width * 1.04, y: size.height * 0.64)
                        )
                        context.stroke(
                            river,
                            with: .color(Color(red: 0.61, green: 0.80, blue: 0.90).opacity(0.72)),
                            style: StrokeStyle(lineWidth: 27, lineCap: .round)
                        )

                        context.fill(
                            Path(roundedRect: CGRect(x: size.width * 0.07, y: size.height * 0.28, width: size.width * 0.18, height: size.height * 0.22), cornerRadius: 18),
                            with: .color(Color(red: 0.73, green: 0.82, blue: 0.64).opacity(0.70))
                        )
                        context.fill(
                            Path(roundedRect: CGRect(x: size.width * 0.57, y: size.height * 0.58, width: size.width * 0.16, height: size.height * 0.20), cornerRadius: 16),
                            with: .color(Color(red: 0.73, green: 0.82, blue: 0.64).opacity(0.62))
                        )

                        for street in minorRoads {
                            context.stroke(
                                roadPath(street, size: size),
                                with: .color(Color.white.opacity(0.55)),
                                style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
                            )
                        }

                        for road in cityRoads {
                            let path = roadPath(road, size: size)
                            context.stroke(
                                path,
                                with: .color(Color.white.opacity(0.92)),
                                style: StrokeStyle(lineWidth: 6.2, lineCap: .round, lineJoin: .round)
                            )
                            context.stroke(
                                path,
                                with: .color(Color(red: 0.70, green: 0.68, blue: 0.63).opacity(0.46)),
                                style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round)
                            )
                        }

                        let route = routePath(size: size)
                        let routeProgress = route.trimmedPath(from: 0, to: progress)
                        context.stroke(routeProgress, with: .color(Color.white.opacity(0.88)), style: StrokeStyle(lineWidth: 7.0, lineCap: .round, lineJoin: .round))
                        context.stroke(routeProgress, with: .color(OnboardingPalette.blue), style: StrokeStyle(lineWidth: 4.2, lineCap: .round, lineJoin: .round))

                        let marker = routePoint(progress: progress, size: size)
                        let markerOpacity = progress > 0.01 && progress < 0.99 ? CGFloat(1) : CGFloat(0)
                        context.fill(Path(ellipseIn: CGRect(x: marker.x - 7, y: marker.y - 7, width: 14, height: 14)), with: .color(Color.white.opacity(0.96 * markerOpacity)))
                        context.fill(Path(ellipseIn: CGRect(x: marker.x - 3.5, y: marker.y - 3.5, width: 7, height: 7)), with: .color(OnboardingPalette.blue.opacity(markerOpacity)))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                    VStack(spacing: 0) {
                        HStack(alignment: .center) {
                            Text("AUTO RECORDING")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(1.25)

                            Spacer()

                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color(red: 0.18, green: 0.62, blue: 0.34))
                                    .frame(width: 6, height: 6)
                                Text("記録中")
                            }
                            .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(OnboardingPalette.ink.opacity(0.72))
                        .padding(.horizontal, 16)
                        .padding(.top, 14)

                        Spacer()

                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("今日の移動")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(OnboardingPalette.mutedInk)
                                Text(String(format: "%.1f km", 0.3 + Double(progress) * 2.4))
                                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                                    .contentTransition(.numericText())
                                    .foregroundStyle(OnboardingPalette.ink)
                            }

                            Spacer()

                            Image(systemName: "location.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(OnboardingPalette.blue)
                                .frame(width: 34, height: 34)
                                .background(Color.white.opacity(0.78), in: Circle())
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                    }
                }
                .opacity(mapReveal * loopOpacity)
                .scaleEffect(0.975 + 0.025 * mapReveal)
            }
        }
        .padding(.horizontal, 1)
        .padding(.vertical, 7)
    }

    private let cityRoads: [[CGPoint]] = [
        [CGPoint(x: -0.04, y: 0.20), CGPoint(x: 0.18, y: 0.20), CGPoint(x: 0.48, y: 0.20), CGPoint(x: 0.78, y: 0.20), CGPoint(x: 1.04, y: 0.20)],
        [CGPoint(x: -0.04, y: 0.45), CGPoint(x: 0.18, y: 0.45), CGPoint(x: 0.48, y: 0.45), CGPoint(x: 0.78, y: 0.45), CGPoint(x: 1.04, y: 0.45)],
        [CGPoint(x: -0.04, y: 0.72), CGPoint(x: 0.18, y: 0.72), CGPoint(x: 0.48, y: 0.72), CGPoint(x: 0.78, y: 0.72), CGPoint(x: 1.04, y: 0.72)],
        [CGPoint(x: 0.18, y: -0.05), CGPoint(x: 0.18, y: 0.20), CGPoint(x: 0.18, y: 0.45), CGPoint(x: 0.18, y: 0.72), CGPoint(x: 0.18, y: 1.05)],
        [CGPoint(x: 0.48, y: -0.05), CGPoint(x: 0.48, y: 0.20), CGPoint(x: 0.48, y: 0.45), CGPoint(x: 0.48, y: 0.72), CGPoint(x: 0.48, y: 1.05)],
        [CGPoint(x: 0.78, y: -0.05), CGPoint(x: 0.78, y: 0.20), CGPoint(x: 0.78, y: 0.45), CGPoint(x: 0.78, y: 0.72), CGPoint(x: 0.78, y: 1.05)]
    ]

    private let minorRoads: [[CGPoint]] = [
        [CGPoint(x: 0.03, y: 0.10), CGPoint(x: 0.10, y: 0.13), CGPoint(x: 0.18, y: 0.12)],
        [CGPoint(x: 0.29, y: 0.05), CGPoint(x: 0.31, y: 0.20), CGPoint(x: 0.29, y: 0.34)],
        [CGPoint(x: 0.58, y: 0.06), CGPoint(x: 0.61, y: 0.20), CGPoint(x: 0.59, y: 0.35)],
        [CGPoint(x: 0.04, y: 0.33), CGPoint(x: 0.18, y: 0.34), CGPoint(x: 0.33, y: 0.32)],
        [CGPoint(x: 0.36, y: 0.28), CGPoint(x: 0.38, y: 0.45), CGPoint(x: 0.36, y: 0.62)],
        [CGPoint(x: 0.57, y: 0.30), CGPoint(x: 0.66, y: 0.32), CGPoint(x: 0.78, y: 0.30)],
        [CGPoint(x: 0.03, y: 0.84), CGPoint(x: 0.18, y: 0.86), CGPoint(x: 0.34, y: 0.84)],
        [CGPoint(x: 0.57, y: 0.86), CGPoint(x: 0.65, y: 0.72), CGPoint(x: 0.74, y: 0.85)],
        [CGPoint(x: 0.27, y: 0.58), CGPoint(x: 0.36, y: 0.56), CGPoint(x: 0.48, y: 0.59)]
    ]

    private func roadPath(_ road: [CGPoint], size: CGSize) -> Path {
        var path = Path()
        path.addLines(road.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
        return path
    }

    private func routePath(size: CGSize) -> Path {
        var path = Path()
        path.addLines(recordingRoute.map { mapPoint($0, size: size) })
        return path
    }

    private func routePoint(progress: CGFloat, size: CGSize) -> CGPoint {
        let points = recordingRoute.map { mapPoint($0, size: size) }
        guard points.count > 1 else { return points.first ?? .zero }

        let segmentLengths = zip(points, points.dropFirst()).map {
            hypot($1.x - $0.x, $1.y - $0.y)
        }
        let totalLength = segmentLengths.reduce(0, +)
        var remaining = totalLength * clamp(progress)

        for index in segmentLengths.indices {
            let length = segmentLengths[index]
            if remaining <= length || index == segmentLengths.count - 1 {
                let fraction = length > 0 ? min(1, remaining / length) : 0
                return CGPoint(
                    x: points[index].x + (points[index + 1].x - points[index].x) * fraction,
                    y: points[index].y + (points[index + 1].y - points[index].y) * fraction
                )
            }
            remaining -= length
        }

        return points.last ?? .zero
    }

    /// すべての頂点を cityRoads の交差点上に置き、記録線が必ず道路に重なるようにする。
    private let recordingRoute: [CGPoint] = [
        CGPoint(x: 0.18, y: 0.92),
        CGPoint(x: 0.18, y: 0.72),
        CGPoint(x: 0.48, y: 0.72),
        CGPoint(x: 0.48, y: 0.45),
        CGPoint(x: 0.78, y: 0.45),
        CGPoint(x: 0.78, y: 0.20),
        CGPoint(x: 0.94, y: 0.20)
    ]

    private func mapPoint(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }

    private func smooth(_ value: CGFloat) -> CGFloat {
        let value = clamp(value)
        return value * value * (3 - 2 * value)
    }
}

private struct RecordingSettingsArtwork: View {
    let locationState: PermissionVisualState
    let locationDetail: String
    let motionState: PermissionVisualState
    let motionDetail: String

    var body: some View {
        VStack(spacing: 0) {
            settingRow(symbol: "location.fill", title: "常時記録", detail: "アプリを閉じても記録", selected: true)
            Divider().padding(.leading, 56)
            settingRow(symbol: "app.fill", title: "アプリ起動中のみ", detail: "使用中とバックグラウンドで記録", selected: false)
            Divider().padding(.leading, 56)
            settingRow(symbol: "pause.fill", title: "記録しない", detail: "位置情報の取得を停止", selected: false)

            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("履歴はこのiPhone内に保存")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Image(systemName: statusSymbol)
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(statusColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(OnboardingPalette.map.opacity(0.55))
        }
        .background(OnboardingPalette.white, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(.black.opacity(0.07), lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(locationDetail) \(motionDetail)")
    }

    private func settingRow(symbol: String, title: String, detail: String, selected: Bool) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? OnboardingPalette.blue : OnboardingPalette.mutedInk)
                .frame(width: 30, height: 30)
                .background((selected ? OnboardingPalette.blue.opacity(0.10) : Color.black.opacity(0.04)), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.ink)
                Text(LocalizedStringKey(detail))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(OnboardingPalette.mutedInk)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(selected ? OnboardingPalette.blue : Color.black.opacity(0.14))
        }
        .padding(.horizontal, 16)
        .frame(height: 68)
    }

    private var statusColor: Color {
        switch locationState {
        case .denied: return .red
        case .attention: return .orange
        default: return OnboardingPalette.mutedInk
        }
    }

    private var statusSymbol: String {
        switch locationState {
        case .complete: return "checkmark.circle.fill"
        case .denied: return "exclamationmark.circle.fill"
        default: return "arrow.right.circle"
        }
    }
}

private enum ExplorationMapMode {
    case visited
    case unvisited
}

private struct ExplorationMapArtwork: View {
    let mode: ExplorationMapMode

    private let visitedRoadIndices = Set([0, 2, 4, 6, 8, 10, 12])

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let cycle = CGFloat(time.truncatingRemainder(dividingBy: 6.2) / 6.2)
            let highlightColor: Color = mode == .visited
                ? Color(red: 0.30, green: 0.67, blue: 1.0)
                : Color(red: 0.78, green: 0.92, blue: 0.22)
            let roadCount = roads.count

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(Color(red: 0.035, green: 0.055, blue: 0.10))
                        .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(0.13), lineWidth: 1))
                        .shadow(color: highlightColor.opacity(0.14), radius: 26, y: 14)

                    Canvas { context, size in
                        // 細い生活道路と地形の面を先に敷き、ルートだけの図形に見えないようにする。
                        for road in minorRoads {
                            let path = roadPath(road, size: size)
                            context.stroke(
                                path,
                                with: .color(.white.opacity(0.075)),
                                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
                            )
                        }

                        var river = Path()
                        river.move(to: CGPoint(x: size.width * 0.86, y: -10))
                        river.addCurve(
                            to: CGPoint(x: size.width * 0.66, y: size.height + 10),
                            control1: CGPoint(x: size.width * 0.72, y: size.height * 0.26),
                            control2: CGPoint(x: size.width * 0.98, y: size.height * 0.58)
                        )
                        context.stroke(river, with: .color(Color(red: 0.10, green: 0.33, blue: 0.48).opacity(0.34)), lineWidth: 12)

                        let parks = [
                            CGRect(x: size.width * 0.07, y: size.height * 0.08, width: size.width * 0.18, height: size.height * 0.11),
                            CGRect(x: size.width * 0.54, y: size.height * 0.68, width: size.width * 0.19, height: size.height * 0.13)
                        ]
                        for park in parks {
                            context.fill(Path(roundedRect: park, cornerRadius: 8), with: .color(Color(red: 0.15, green: 0.34, blue: 0.25).opacity(0.25)))
                        }

                        for (index, road) in roads.enumerated() {
                            let path = roadPath(road, size: size)
                            let isVisitedRoad = visitedRoadIndices.contains(index)
                            let isHighlighted = mode == .visited ? isVisitedRoad : !isVisitedRoad
                            let order = mode == .visited
                                ? visitedOrder(for: index)
                                : unvisitedOrder(for: index)
                            let progress = isHighlighted
                                ? min(1, max(0, (cycle - CGFloat(order) * 0.075) * 2.15))
                                : 0

                            // 街の道路網は常に見せ、歩いた／未踏の差だけを強調する。
                            context.stroke(
                                path,
                                with: .color(.white.opacity(isHighlighted ? 0.12 : 0.065)),
                                style: StrokeStyle(lineWidth: isHighlighted ? 6 : 2, lineCap: .round, lineJoin: .round)
                            )

                            if progress > 0 {
                                context.drawLayer { layer in
                                    layer.addFilter(.shadow(color: highlightColor.opacity(0.85), radius: 9))
                                    layer.stroke(
                                        path.trimmedPath(from: 0, to: progress),
                                        with: .color(highlightColor.opacity(0.96)),
                                        style: StrokeStyle(lineWidth: isHighlighted ? 3.2 : 2, lineCap: .round, lineJoin: .round)
                                    )
                                }
                            }
                        }

                        // 道路の交差点を点で残して、地図らしい密度を出す。
                        for road in roads {
                            for point in road {
                                let center = CGPoint(x: point.x * size.width, y: point.y * size.height)
                                context.fill(
                                    Path(ellipseIn: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)),
                                    with: .color(.white.opacity(0.20))
                                )
                            }
                        }

                        let animatedIndex = mode == .visited ? 12 : 13
                        let markerProgress = min(1, max(0.03, (cycle * 1.24).truncatingRemainder(dividingBy: 1)))
                        let marker = roadPoint(roads[animatedIndex], progress: markerProgress, size: size)
                        let pulse = 7 + CGFloat(sin(time * 4.0)) * 2
                        context.fill(Path(ellipseIn: CGRect(x: marker.x - 3.5, y: marker.y - 3.5, width: 7, height: 7)), with: .color(.white))
                        context.stroke(
                            Path(ellipseIn: CGRect(x: marker.x - pulse, y: marker.y - pulse, width: pulse * 2, height: pulse * 2)),
                            with: .color(highlightColor.opacity(0.55)),
                            lineWidth: 1.2
                        )
                    }
                    .padding(13)

                    VStack {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode == .visited ? "VISITED ROADS" : "UNEXPLORED ROADS")
                                    .font(.system(size: 8, weight: .bold))
                                    .tracking(1.5)
                                    .foregroundStyle(.white.opacity(0.54))
                                Text(mode == .visited ? "07 / \(roadCount)" : "07 LEFT")
                                    .font(.system(size: 28, weight: .light, design: .rounded))
                                    .foregroundStyle(.white)
                            }
                            Spacer()
                            Image(systemName: mode == .visited ? "figure.walk" : "sparkles")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(highlightColor)
                        }
                        Spacer()
                        HStack {
                            Text(mode == .visited ? "YOUR TRACE" : "NEXT WALK")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(1.6)
                                .foregroundStyle(.white.opacity(0.48))
                            Spacer()
                            Text(mode == .visited ? "RECORDED" : "FIND ONE MORE")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(1.2)
                                .foregroundStyle(highlightColor)
                        }
                    }
                    .padding(21)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private var roads: [[CGPoint]] {
        [
            [CGPoint(x: 0.02, y: 0.20), CGPoint(x: 0.28, y: 0.28), CGPoint(x: 0.58, y: 0.18), CGPoint(x: 0.98, y: 0.30)],
            [CGPoint(x: 0.01, y: 0.43), CGPoint(x: 0.30, y: 0.39), CGPoint(x: 0.62, y: 0.48), CGPoint(x: 0.99, y: 0.40)],
            [CGPoint(x: 0.02, y: 0.72), CGPoint(x: 0.34, y: 0.62), CGPoint(x: 0.70, y: 0.77), CGPoint(x: 0.98, y: 0.63)],
            [CGPoint(x: 0.17, y: 0.00), CGPoint(x: 0.23, y: 0.30), CGPoint(x: 0.16, y: 0.98)],
            [CGPoint(x: 0.47, y: 0.00), CGPoint(x: 0.51, y: 0.32), CGPoint(x: 0.46, y: 0.98)],
            [CGPoint(x: 0.80, y: 0.00), CGPoint(x: 0.71, y: 0.34), CGPoint(x: 0.84, y: 0.98)],
            [CGPoint(x: 0.08, y: 0.90), CGPoint(x: 0.25, y: 0.56), CGPoint(x: 0.50, y: 0.34), CGPoint(x: 0.91, y: 0.08)],
            [CGPoint(x: 0.08, y: 0.08), CGPoint(x: 0.34, y: 0.25), CGPoint(x: 0.61, y: 0.54), CGPoint(x: 0.91, y: 0.91)],
            [CGPoint(x: 0.04, y: 0.58), CGPoint(x: 0.26, y: 0.46), CGPoint(x: 0.55, y: 0.62), CGPoint(x: 0.92, y: 0.50)],
            [CGPoint(x: 0.37, y: 0.04), CGPoint(x: 0.35, y: 0.31), CGPoint(x: 0.57, y: 0.73), CGPoint(x: 0.66, y: 0.96)],
            [CGPoint(x: 0.63, y: 0.03), CGPoint(x: 0.56, y: 0.27), CGPoint(x: 0.31, y: 0.75), CGPoint(x: 0.20, y: 0.96)],
            [CGPoint(x: 0.05, y: 0.34), CGPoint(x: 0.38, y: 0.51), CGPoint(x: 0.65, y: 0.43), CGPoint(x: 0.97, y: 0.56)],
            [CGPoint(x: 0.04, y: 0.94), CGPoint(x: 0.24, y: 0.74), CGPoint(x: 0.48, y: 0.82), CGPoint(x: 0.92, y: 0.70)],
            [CGPoint(x: 0.93, y: 0.04), CGPoint(x: 0.73, y: 0.25), CGPoint(x: 0.47, y: 0.44), CGPoint(x: 0.10, y: 0.61)]
        ]
    }

    private var minorRoads: [[CGPoint]] {
        [
            [CGPoint(x: 0.02, y: 0.12), CGPoint(x: 0.19, y: 0.16), CGPoint(x: 0.39, y: 0.11)],
            [CGPoint(x: 0.27, y: 0.08), CGPoint(x: 0.31, y: 0.21), CGPoint(x: 0.30, y: 0.33)],
            [CGPoint(x: 0.58, y: 0.06), CGPoint(x: 0.62, y: 0.17), CGPoint(x: 0.59, y: 0.30)],
            [CGPoint(x: 0.74, y: 0.13), CGPoint(x: 0.87, y: 0.19), CGPoint(x: 0.98, y: 0.15)],
            [CGPoint(x: 0.04, y: 0.31), CGPoint(x: 0.17, y: 0.36), CGPoint(x: 0.28, y: 0.34)],
            [CGPoint(x: 0.36, y: 0.27), CGPoint(x: 0.42, y: 0.38), CGPoint(x: 0.40, y: 0.48)],
            [CGPoint(x: 0.69, y: 0.28), CGPoint(x: 0.78, y: 0.37), CGPoint(x: 0.96, y: 0.34)],
            [CGPoint(x: 0.05, y: 0.53), CGPoint(x: 0.17, y: 0.58), CGPoint(x: 0.30, y: 0.54)],
            [CGPoint(x: 0.37, y: 0.56), CGPoint(x: 0.43, y: 0.65), CGPoint(x: 0.41, y: 0.78)],
            [CGPoint(x: 0.62, y: 0.51), CGPoint(x: 0.75, y: 0.57), CGPoint(x: 0.95, y: 0.54)],
            [CGPoint(x: 0.06, y: 0.79), CGPoint(x: 0.18, y: 0.84), CGPoint(x: 0.34, y: 0.81)],
            [CGPoint(x: 0.51, y: 0.84), CGPoint(x: 0.59, y: 0.74), CGPoint(x: 0.70, y: 0.86)],
            [CGPoint(x: 0.78, y: 0.74), CGPoint(x: 0.86, y: 0.82), CGPoint(x: 0.98, y: 0.79)]
        ]
    }

    private func roadPath(_ road: [CGPoint], size: CGSize) -> Path {
        var path = Path()
        path.addLines(road.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
        return path
    }

    private func visitedOrder(for index: Int) -> Int {
        visitedRoadIndices.sorted().firstIndex(of: index) ?? 0
    }

    private func unvisitedOrder(for index: Int) -> Int {
        roads.indices.filter { !visitedRoadIndices.contains($0) }.firstIndex(of: index) ?? 0
    }

    private func roadPoint(_ road: [CGPoint], progress: CGFloat, size: CGSize) -> CGPoint {
        let lengths = zip(road, road.dropFirst()).map { hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) }
        let total = max(0.0001, lengths.reduce(0, +))
        var remaining = min(1, max(0, progress)) * total
        for (index, length) in lengths.enumerated() {
            if remaining <= length {
                let fraction = remaining / max(0.0001, length)
                let start = road[index]
                let end = road[index + 1]
                return CGPoint(
                    x: (start.x + (end.x - start.x) * fraction) * size.width,
                    y: (start.y + (end.y - start.y) * fraction) * size.height
                )
            }
            remaining -= length
        }
        let last = road.last ?? .zero
        return CGPoint(x: last.x * size.width, y: last.y * size.height)
    }
}

private struct PersonalMapArtwork: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let cycle = CGFloat(time.truncatingRemainder(dividingBy: 4.2) / 4.2)
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 34, style: .continuous)
                                .fill(Color(red: 0.035, green: 0.055, blue: 0.12).opacity(0.62))
                        }
                        .overlay(RoundedRectangle(cornerRadius: 34).stroke(.white.opacity(0.16), lineWidth: 1))
                        .shadow(color: Color.blue.opacity(0.2), radius: 30, y: 16)

                    Canvas { context, size in
                        let roads: [[CGPoint]] = [
                            [p(0.03, 0.22, size), p(0.28, 0.31, size), p(0.56, 0.23, size), p(0.97, 0.34, size)],
                            [p(0.04, 0.72, size), p(0.31, 0.59, size), p(0.62, 0.68, size), p(0.96, 0.55, size)],
                            [p(0.16, 0.02, size), p(0.25, 0.36, size), p(0.19, 0.98, size)],
                            [p(0.49, 0.01, size), p(0.53, 0.43, size), p(0.44, 0.98, size)],
                            [p(0.81, 0.02, size), p(0.70, 0.41, size), p(0.85, 0.98, size)]
                        ]
                        for road in roads {
                            var path = Path()
                            path.addLines(road)
                            context.stroke(path, with: .color(.white.opacity(0.075)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                        }

                        var route = Path()
                        route.move(to: p(0.06, 0.78, size))
                        route.addCurve(to: p(0.34, 0.55, size), control1: p(0.15, 0.78, size), control2: p(0.22, 0.49, size))
                        route.addCurve(to: p(0.57, 0.25, size), control1: p(0.45, 0.61, size), control2: p(0.43, 0.28, size))
                        route.addCurve(to: p(0.92, 0.38, size), control1: p(0.69, 0.18, size), control2: p(0.80, 0.44, size))
                        route.addCurve(to: p(0.84, 0.79, size), control1: p(0.98, 0.52, size), control2: p(0.76, 0.66, size))

                        context.stroke(route, with: .color(Color.blue.opacity(0.18)), style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                        context.drawLayer { layer in
                            layer.addFilter(.shadow(color: Color(red: 0.25, green: 0.62, blue: 1).opacity(0.9), radius: 10))
                            layer.stroke(
                                route.trimmedPath(from: 0, to: max(0.08, cycle)),
                                with: .color(Color(red: 0.31, green: 0.68, blue: 1.0)),
                                style: StrokeStyle(lineWidth: 4.4, lineCap: .round, lineJoin: .round)
                            )
                        }

                        let pulse = 8 + CGFloat(sin(time * 3.1)) * 3
                        let pulseCenter = p(0.57, 0.25, size)
                        context.stroke(
                            Path(ellipseIn: CGRect(x: pulseCenter.x - pulse, y: pulseCenter.y - pulse, width: pulse * 2, height: pulse * 2)),
                            with: .color(Color.white.opacity(0.34)),
                            lineWidth: 1.2
                        )
                    }
                    .padding(16)

                    VStack {
                        HStack {
                            Text("LIVE TRACE")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(1.8)
                            Spacer()
                            HStack(spacing: 5) {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                                    .shadow(color: .green, radius: 5)
                                Text("RECORDING")
                            }
                            .font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(.white.opacity(0.64))
                        Spacer()
                        HStack(alignment: .lastTextBaseline) {
                            Text(String(format: "%.1f", 1.2 + Double(cycle) * 3.6))
                                .font(.system(size: 30, weight: .light, design: .rounded))
                            Text("km")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                            Spacer()
                            Image(systemName: "location.north.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color(red: 0.31, green: 0.68, blue: 1.0))
                                .rotationEffect(.degrees(Double(sin(time * 0.8)) * 12))
                        }
                        .foregroundStyle(.white)
                    }
                    .padding(21)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func p(_ x: CGFloat, _ y: CGFloat, _ size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }
}

private struct GrowingMapArtwork: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let cycle = CGFloat(time.truncatingRemainder(dividingBy: 5.6) / 5.6)
            let mainProgress = min(1, max(0.05, cycle * 2.25))
            let branchProgress = min(1, max(0, (cycle - 0.28) * 3.1))
            let finalProgress = min(1, max(0, (cycle - 0.54) * 3.0))
            let completion = (mainProgress + branchProgress + finalProgress) / 3
            GeometryReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(Color(red: 0.025, green: 0.04, blue: 0.075).opacity(0.92))
                        .overlay(RoundedRectangle(cornerRadius: 34).stroke(.white.opacity(0.14), lineWidth: 1))
                        .shadow(color: Color.green.opacity(0.14), radius: 30, y: 16)

                    Canvas { context, size in
                        for road in backgroundRoads(size) {
                            context.stroke(
                                road,
                                with: .color(.white.opacity(0.065)),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                            )
                        }

                        let routes: [(Path, Color, CGFloat)] = [
                            (routeA(size), Color(red: 0.74, green: 0.91, blue: 0.20), mainProgress),
                            (routeB(size), Color(red: 0.17, green: 0.84, blue: 0.75), branchProgress),
                            (routeC(size), Color(red: 0.38, green: 0.58, blue: 1.0), finalProgress)
                        ]
                        for (path, color, progress) in routes {
                            context.stroke(path, with: .color(.white.opacity(0.055)), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                            context.drawLayer { layer in
                                layer.addFilter(.shadow(color: color.opacity(0.72), radius: 8))
                                layer.stroke(path.trimmedPath(from: 0, to: progress), with: .color(color), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                            }
                        }

                        let marker = routeAPoint(mainProgress, size: size)
                        let pulse = 8 + CGFloat(sin(time * 4.2)) * 2.5
                        context.fill(Path(ellipseIn: CGRect(x: marker.x - 3, y: marker.y - 3, width: 6, height: 6)), with: .color(.white))
                        context.stroke(
                            Path(ellipseIn: CGRect(x: marker.x - pulse, y: marker.y - pulse, width: pulse * 2, height: pulse * 2)),
                            with: .color(Color(red: 0.74, green: 0.91, blue: 0.20).opacity(0.48)),
                            lineWidth: 1.4
                        )

                        if branchProgress > 0.78 {
                            context.draw(
                                Text("+ NEW").font(.system(size: 8, weight: .bold)).foregroundStyle(Color(red: 0.17, green: 0.84, blue: 0.75)),
                                at: CGPoint(x: size.width * 0.31, y: size.height * 0.07)
                            )
                        }
                        if finalProgress > 0.78 {
                            context.draw(
                                Text("+ NEW").font(.system(size: 8, weight: .bold)).foregroundStyle(Color(red: 0.38, green: 0.58, blue: 1.0)),
                                at: CGPoint(x: size.width * 0.84, y: size.height * 0.92)
                            )
                        }
                    }
                    .padding(14)

                    VStack {
                        HStack(alignment: .top) {
                            metric("NEW ROADS", value: "+\(Int(4 + completion * 39))")
                            Spacer()
                            metric("DISTANCE", value: String(format: "%.1f", 1.3 + Double(completion) * 10.9), unit: "km")
                        }
                        Spacer()
                        HStack {
                            Label("EXPLORATION MAP", systemImage: "sparkles")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(1.2)
                                .foregroundStyle(.white.opacity(0.5))
                            Spacer()
                            Text("\(Int(1 + completion * 11)) ACTIVE DAYS")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(1.1)
                                .foregroundStyle(Color(red: 0.74, green: 0.91, blue: 0.20))
                        }
                    }
                    .padding(22)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func metric(_ label: String, value: String, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .tracking(1.3)
                .foregroundStyle(.white.opacity(0.48))
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 31, weight: .light, design: .rounded))
                if let unit { Text(unit).font(.system(size: 10, weight: .semibold)).opacity(0.58) }
            }
            .foregroundStyle(.white)
        }
    }

    private func routeA(_ size: CGSize) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: size.width * 0.08, y: size.height * 0.76))
        path.addCurve(to: CGPoint(x: size.width * 0.91, y: size.height * 0.23), control1: CGPoint(x: size.width * 0.26, y: size.height * 0.42), control2: CGPoint(x: size.width * 0.57, y: size.height * 0.88))
        return path
    }

    private func routeB(_ size: CGSize) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: size.width * 0.44, y: size.height * 0.56))
        path.addCurve(to: CGPoint(x: size.width * 0.31, y: size.height * 0.10), control1: CGPoint(x: size.width * 0.34, y: size.height * 0.42), control2: CGPoint(x: size.width * 0.43, y: size.height * 0.25))
        return path
    }

    private func routeC(_ size: CGSize) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: size.width * 0.60, y: size.height * 0.57))
        path.addCurve(to: CGPoint(x: size.width * 0.84, y: size.height * 0.88), control1: CGPoint(x: size.width * 0.76, y: size.height * 0.54), control2: CGPoint(x: size.width * 0.68, y: size.height * 0.82))
        return path
    }

    private func backgroundRoads(_ size: CGSize) -> [Path] {
        let lines: [[CGPoint]] = [
            [CGPoint(x: 0.04, y: 0.18), CGPoint(x: 0.34, y: 0.29), CGPoint(x: 0.68, y: 0.18), CGPoint(x: 0.97, y: 0.31)],
            [CGPoint(x: 0.02, y: 0.48), CGPoint(x: 0.31, y: 0.43), CGPoint(x: 0.65, y: 0.52), CGPoint(x: 0.98, y: 0.45)],
            [CGPoint(x: 0.06, y: 0.83), CGPoint(x: 0.38, y: 0.72), CGPoint(x: 0.72, y: 0.81), CGPoint(x: 0.96, y: 0.68)],
            [CGPoint(x: 0.19, y: 0.02), CGPoint(x: 0.25, y: 0.35), CGPoint(x: 0.18, y: 0.97)],
            [CGPoint(x: 0.52, y: 0.02), CGPoint(x: 0.49, y: 0.44), CGPoint(x: 0.56, y: 0.98)],
            [CGPoint(x: 0.81, y: 0.03), CGPoint(x: 0.74, y: 0.39), CGPoint(x: 0.87, y: 0.97)]
        ]
        return lines.map { normalized in
            var path = Path()
            path.addLines(normalized.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
            return path
        }
    }

    private func routeAPoint(_ progress: CGFloat, size: CGSize) -> CGPoint {
        let t = min(1, max(0, progress))
        let inverse = 1 - t
        let p0 = CGPoint(x: size.width * 0.08, y: size.height * 0.76)
        let p1 = CGPoint(x: size.width * 0.26, y: size.height * 0.42)
        let p2 = CGPoint(x: size.width * 0.57, y: size.height * 0.88)
        let p3 = CGPoint(x: size.width * 0.91, y: size.height * 0.23)
        return CGPoint(
            x: inverse * inverse * inverse * p0.x
                + 3 * inverse * inverse * t * p1.x
                + 3 * inverse * t * t * p2.x
                + t * t * t * p3.x,
            y: inverse * inverse * inverse * p0.y
                + 3 * inverse * inverse * t * p1.y
                + 3 * inverse * t * t * p2.y
                + t * t * t * p3.y
        )
    }
}

private struct PermissionRadarArtwork: View {
    let locationState: PermissionVisualState
    let locationDetail: String
    let motionState: PermissionVisualState
    let motionDetail: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 34, style: .continuous)
                                .fill(Color(red: 0.025, green: 0.075, blue: 0.075).opacity(0.64))
                        }
                        .overlay(RoundedRectangle(cornerRadius: 34).stroke(.white.opacity(0.15), lineWidth: 1))
                        .shadow(color: Color.green.opacity(0.16), radius: 30, y: 16)

                    Canvas { context, size in
                        let center = CGPoint(x: size.width / 2, y: size.height * 0.42)
                        let phase = CGFloat(time.truncatingRemainder(dividingBy: 2.4) / 2.4)
                        for index in 0..<3 {
                            let local = (phase + CGFloat(index) / 3).truncatingRemainder(dividingBy: 1)
                            let radius = 34 + local * 78
                            context.stroke(
                                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                                with: .color(Color(red: 0.26, green: 0.95, blue: 0.73).opacity(Double(1 - local) * 0.28)),
                                lineWidth: 1.3
                            )
                        }
                    }

                    VStack(spacing: 0) {
                        HStack {
                            Label("ON-DEVICE PRIVACY", systemImage: "lock.shield.fill")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(1.3)
                                .foregroundStyle(.white.opacity(0.58))
                            Spacer()
                            Circle()
                                .fill(Color(red: 0.26, green: 0.95, blue: 0.73))
                                .frame(width: 7, height: 7)
                                .shadow(color: .green, radius: 7)
                        }

                        Spacer()

                        ZStack {
                            Circle()
                                .fill(Color(red: 0.26, green: 0.95, blue: 0.73).opacity(0.15))
                                .frame(width: 76, height: 76)
                                .scaleEffect(1 + CGFloat(sin(time * 2.1)) * 0.04)
                            Circle()
                                .stroke(.white.opacity(0.16), lineWidth: 1)
                                .frame(width: 76, height: 76)
                            Image(systemName: "location.fill")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(Color(red: 0.34, green: 0.96, blue: 0.75))
                                .shadow(color: Color.green.opacity(0.55), radius: 10)
                        }

                        Spacer()

                        HStack(spacing: 7) {
                            PermissionStateChip(symbol: "location.fill", title: "位置情報", state: locationState)
                            PermissionStateChip(symbol: "figure.walk.motion", title: "モーション", state: motionState)
                            PermissionStateChip(symbol: "iphone.gen3", title: "端末内", state: .complete)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(locationDetail) \(motionDetail)")
    }
}

private struct PermissionStateChip: View {
    let symbol: String
    let title: String
    let state: PermissionVisualState

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
            Text(LocalizedStringKey(title))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(1)
            Image(systemName: stateSymbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.09), lineWidth: 1))
    }

    private var color: Color {
        switch state {
        case .pending: Color(red: 0.40, green: 0.67, blue: 1.0)
        case .attention: .orange
        case .complete: Color(red: 0.34, green: 0.96, blue: 0.75)
        case .denied: .red
        }
    }

    private var stateSymbol: String {
        switch state {
        case .pending: "ellipsis"
        case .attention: "exclamationmark"
        case .complete: "checkmark"
        case .denied: "xmark"
        }
    }
}

private struct OnboardingPageLayout<Artwork: View>: View {
    let eyebrow: String
    let title: String
    let message: String
    @ViewBuilder let artwork: Artwork

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 6)

            artwork
                .frame(maxWidth: 370)
                .frame(height: 300)

            VStack(alignment: .leading, spacing: 10) {
                Text(LocalizedStringKey(eyebrow))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.blue)

                Text(LocalizedStringKey(title))
                    .font(.system(size: 35, weight: .bold))
                    .tracking(-1.25)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(1)
                    .foregroundStyle(OnboardingPalette.ink)

                Text(LocalizedStringKey(message))
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(OnboardingPalette.mutedInk)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 24)
    }
}

private struct RouteMapArtwork: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(.white.opacity(0.78))
                    .shadow(color: .black.opacity(0.08), radius: 28, y: 14)

                Canvas { context, size in
                    let roads: [[CGPoint]] = [
                        [p(0.05, 0.23, size), p(0.35, 0.34, size), p(0.94, 0.21, size)],
                        [p(0.10, 0.73, size), p(0.42, 0.58, size), p(0.91, 0.76, size)],
                        [p(0.22, 0.04, size), p(0.31, 0.41, size), p(0.26, 0.95, size)],
                        [p(0.66, 0.02, size), p(0.59, 0.46, size), p(0.72, 0.96, size)],
                        [p(0.02, 0.49, size), p(0.48, 0.46, size), p(0.98, 0.52, size)]
                    ]
                    for points in roads {
                        var path = Path()
                        path.addLines(points)
                        context.stroke(path, with: .color(.black.opacity(0.09)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }

                    var visited = Path()
                    visited.move(to: p(0.10, 0.73, size))
                    visited.addCurve(
                        to: p(0.31, 0.41, size),
                        control1: p(0.19, 0.67, size),
                        control2: p(0.28, 0.56, size)
                    )
                    visited.addCurve(
                        to: p(0.59, 0.46, size),
                        control1: p(0.39, 0.34, size),
                        control2: p(0.50, 0.50, size)
                    )
                    visited.addCurve(
                        to: p(0.91, 0.76, size),
                        control1: p(0.73, 0.43, size),
                        control2: p(0.75, 0.73, size)
                    )
                    context.stroke(
                        visited,
                        with: .color(Color(red: 0.05, green: 0.42, blue: 1.0)),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                    )
                }
                .padding(18)

                VStack {
                    HStack {
                        Text("歩いた道")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Label("次の道へ", systemImage: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Color(red: 0.055, green: 0.07, blue: 0.095), in: Capsule())
                    }
                }
                .padding(18)
            }
        }
        .padding(.horizontal, 8)
    }

    private func p(_ x: CGFloat, _ y: CGFloat, _ size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 15, weight: .semibold))
                Text(LocalizedStringKey(detail))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.48))
            }
            Spacer()
        }
        .padding(14)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.9), lineWidth: 1))
    }
}

private enum PermissionVisualState {
    case pending
    case attention
    case complete
    case denied
}

private struct PermissionStatusRow: View {
    let symbol: String
    let title: String
    let detail: String
    let state: PermissionVisualState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(stateColor)
                .frame(width: 44, height: 44)
                .background(stateColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 15, weight: .semibold))
                Text(LocalizedStringKey(detail))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.48))
            }

            Spacer()

            Image(systemName: stateSymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(stateColor)
        }
        .padding(14)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.9), lineWidth: 1))
    }

    private var stateColor: Color {
        switch state {
        case .pending: Color(red: 0.08, green: 0.39, blue: 0.96)
        case .attention: .orange
        case .complete: Color(red: 0.10, green: 0.62, blue: 0.43)
        case .denied: .red
        }
    }

    private var stateSymbol: String {
        switch state {
        case .pending: "arrow.right.circle"
        case .attention: "exclamationmark.circle.fill"
        case .complete: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        }
    }
}
