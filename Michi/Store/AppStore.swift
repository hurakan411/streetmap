import CoreLocation
import Foundation
import MapKit

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var tracks: [WalkTrack] {
        didSet {
            tracksRevision &+= 1
            invalidateDerivedCaches()
            reviewEligibleActiveDays = calculateReviewEligibleActiveDays(from: tracks)
        }
    }
    @Published private(set) var reviewEligibleActiveDays = 0
    @Published var livePoints: [GeoPoint] = []
    @Published var latestLocation: CLLocation?
    @Published var period: PeriodPreset = .month {
        didSet {
            rangeStartFraction = 0
            rangeEndFraction = 1
            invalidateDerivedCaches()
        }
    }
    @Published var rangeStartFraction: Double = 0 {
        didSet { invalidateDerivedCaches() }
    }
    @Published var rangeEndFraction: Double = 1 {
        didSet { invalidateDerivedCaches() }
    }
    @Published var displayMode: MapDisplayMode = .map
    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "selectedTheme") }
    }
    @Published var showsPointsOfInterest: Bool {
        didSet { UserDefaults.standard.set(showsPointsOfInterest, forKey: "showsPointsOfInterest") }
    }
    @Published var appLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage") }
    }
    @Published var recordingMode: RecordingMode {
        didSet {
            UserDefaults.standard.set(recordingMode.rawValue, forKey: "recordingMode")
            recorder.setRecordingMode(recordingMode)
            if recordingMode != .persistent {
                recoveryAnchor = nil
                lastRecoveryAnchorSaveDate = .distantPast
                historyStore.clearRecoveryAnchor()
            }
        }
    }
    @Published var movementCaptureMode: MovementCaptureMode {
        didSet {
            UserDefaults.standard.set(movementCaptureMode.rawValue, forKey: "movementCaptureMode")
            recorder.setMovementCaptureMode(movementCaptureMode)
        }
    }
    @Published var visibleTransportModes: Set<TransportMode> {
        didSet {
            UserDefaults.standard.set(
                visibleTransportModes.map(\.rawValue).sorted(),
                forKey: "visibleTransportModes"
            )
            cachedStatsKey = nil
        }
    }

    let recorder = LocationRecorder()
    private let historyStore = LocalHistoryStore()
    private let calendar = Calendar.autoupdatingCurrent
    private var liveRawPoints: [GeoPoint] = []
    private var liveRawPointsRevision = 0
    private var liveMatchedPoints: [GeoPoint] = []
    private var matchedRawPointCount = 0
    private var liveRoadMatchTask: Task<Void, Never>?
    private var lastDraftSaveDate = Date.distantPast
    private var lastRecoveryAnchorSaveDate = Date.distantPast
    private var recoveryAnchor: GeoPoint?
    private var tracksRevision = 0
    private var cachedSegmentsKey: String?
    private var cachedSegments: [WeightedSegment] = []
    private var cachedStatsKey: String?
    private var cachedStats = WalkStats.zero

    init() {
        var savedTracks = historyStore.load().sorted { $0.startDate < $1.startDate }
        let recoveredDraft = historyStore.loadDraft()
        if recoveredDraft.count >= 2,
           !savedTracks.contains(where: { $0.rawPoints.last?.timestamp == recoveredDraft.last?.timestamp }) {
            savedTracks.append(WalkTrack(rawPoints: recoveredDraft))
            savedTracks.sort { $0.startDate < $1.startDate }
            historyStore.save(savedTracks)
        }
        historyStore.clearDraft()
        #if targetEnvironment(simulator)
        // シミュレーターは掲載画像用のデモ環境。実機の履歴を変更せず、
        // 新宿駅を中心に毎回同じルート群を表示する。
        let retainedSimulatorTracks = savedTracks.filter { !SampleHistory.isShinjukuPreviewSample($0) }
        tracks = retainedSimulatorTracks + SampleHistory.makeShinjuku()
        #elseif DEBUG
        // Debug実機では、起動直後から地図・頻度・Statsを確認できるよう
        // 過去の直線サンプルを除き、道路補正対象の後楽園サンプルを一度だけ追加します。
        let retainedTracks = savedTracks.filter { !SampleHistory.isLegacyStraightSample($0) }
        let shouldSeedSamples = !UserDefaults.standard.bool(forKey: "debugRoadAlignedKorakuenSamplesV2")
        tracks = shouldSeedSamples ? retainedTracks + SampleHistory.make() : retainedTracks
        #else
        tracks = savedTracks
        #endif
        let savedTheme = UserDefaults.standard.string(forKey: "selectedTheme") ?? ""
        switch savedTheme {
        case "midnight": theme = .midnightPulse
        case "paper": theme = .paperAtlas
        default: theme = AppTheme(rawValue: savedTheme) ?? .editorialGlass
        }
        showsPointsOfInterest = UserDefaults.standard.object(forKey: "showsPointsOfInterest") as? Bool ?? true
        if let savedLanguage = UserDefaults.standard.string(forKey: "appLanguage"),
           let language = AppLanguage(rawValue: savedLanguage) {
            // 旧バージョンで保存された「デバイスの言語」は起動時に解決し、
            // 設定画面では日本語／Englishの2択だけを表示する。
            appLanguage = language == .system ? .deviceDefault : language
        } else {
            appLanguage = .deviceDefault
        }
        if let savedMode = UserDefaults.standard.string(forKey: "recordingMode"),
           let mode = RecordingMode(rawValue: savedMode) {
            recordingMode = mode
        } else {
            let legacyValue = UserDefaults.standard.object(forKey: "recordingEnabled") as? Bool
            recordingMode = legacyValue == false ? .off : .persistent
        }
        if let savedCaptureMode = UserDefaults.standard.string(forKey: "movementCaptureMode"),
           let captureMode = MovementCaptureMode(rawValue: savedCaptureMode) {
            movementCaptureMode = captureMode
        } else {
            movementCaptureMode = .all
        }
        if let savedVisibleModes = UserDefaults.standard.stringArray(forKey: "visibleTransportModes") {
            visibleTransportModes = Set(savedVisibleModes.compactMap(TransportMode.init(rawValue:)))
        } else {
            visibleTransportModes = Set(TransportMode.allCases)
        }
        #if targetEnvironment(simulator)
        historyStore.save(tracks)
        latestLocation = SampleHistory.shinjukuLocation
        #endif
        #if DEBUG
        #if !targetEnvironment(simulator)
        if shouldSeedSamples {
            UserDefaults.standard.set(true, forKey: "debugRoadAlignedKorakuenSamplesV2")
            historyStore.save(tracks)
        }
        #endif
        #endif

        recorder.onLivePointsChanged = { [weak self] points in
            self?.updateLiveRoute(points)
        }
        recorder.onLocationChanged = { [weak self] location in
            #if targetEnvironment(simulator)
            // シミュレーターの実GPSやMacの位置情報に上書きさせない。
            self?.latestLocation = SampleHistory.shinjukuLocation
            #else
            self?.latestLocation = location
            #endif
        }
        recorder.onTrackFinished = { [weak self] points in
            self?.storeFinishedTrack(points)
        }
        if recordingMode == .persistent {
            recoveryAnchor = historyStore.loadRecoveryAnchor()
        } else {
            recoveryAnchor = nil
            historyStore.clearRecoveryAnchor()
        }
        recorder.onPointAccepted = { [weak self] point in
            self?.handleAcceptedPoint(point)
        }
        recorder.onSpeedFiltered = { [weak self] in
            self?.clearRecoveryAnchorAfterSpeedFilter()
        }
        recorder.setMovementCaptureMode(movementCaptureMode)
        recorder.setRecordingMode(recordingMode)
        reviewEligibleActiveDays = calculateReviewEligibleActiveDays(from: tracks)
        matchPendingTracksToRoads()
    }

    var baseDateRange: ClosedRange<Date> {
        let now = Date()
        switch period {
        case .today:
            let start = calendar.startOfDay(for: now)
            return start...max(start, now)
        case .month:
            let interval = calendar.dateInterval(of: .month, for: now)
            let start = interval?.start ?? now
            return start...max(start, now)
        case .year:
            let interval = calendar.dateInterval(of: .year, for: now)
            let start = interval?.start ?? now
            return start...max(start, now)
        case .all:
            let earliest = tracks.map(\.startDate).min() ?? calendar.date(byAdding: .year, value: -1, to: now) ?? now
            return earliest...now
        }
    }

    var selectedDateRange: ClosedRange<Date> {
        let base = baseDateRange
        let duration = max(1, base.upperBound.timeIntervalSince(base.lowerBound))
        let lower = base.lowerBound.addingTimeInterval(duration * rangeStartFraction)
        let upper = base.lowerBound.addingTimeInterval(duration * rangeEndFraction)
        return min(lower, upper)...max(lower, upper)
    }

    func setRangeStartDate(_ date: Date) {
        let base = baseDateRange
        let duration = max(1, base.upperBound.timeIntervalSince(base.lowerBound))
        let minimumGap = duration * 0.025
        let latestStart = max(base.lowerBound, selectedDateRange.upperBound.addingTimeInterval(-minimumGap))
        let clampedDate = min(max(date, base.lowerBound), latestStart)
        rangeStartFraction = min(1, max(0, clampedDate.timeIntervalSince(base.lowerBound) / duration))
    }

    func setRangeEndDate(_ date: Date) {
        let base = baseDateRange
        let duration = max(1, base.upperBound.timeIntervalSince(base.lowerBound))
        let minimumGap = duration * 0.025
        let earliestEnd = min(base.upperBound, selectedDateRange.lowerBound.addingTimeInterval(minimumGap))
        let clampedDate = min(max(date, earliestEnd), base.upperBound)
        rangeEndFraction = min(1, max(0, clampedDate.timeIntervalSince(base.lowerBound) / duration))
    }

    var filteredTracks: [WalkTrack] {
        let range = selectedDateRange
        return tracksForDisplay.filter { $0.endDate >= range.lowerBound && $0.startDate <= range.upperBound }
    }

    private var tracksForDisplay: [WalkTrack] {
        #if targetEnvironment(simulator)
        // デモ軌跡は道路補正が終わってから描画し、仮の直線が地図を横切らないようにする。
        return tracks.filter { $0.isRoadMatched || !SampleHistory.isShinjukuPreviewSample($0) }
        #else
        return tracks
        #endif
    }

    var allWeightedSegments: [WeightedSegment] {
        let key = derivedCacheKey
        if cachedSegmentsKey == key { return cachedSegments }

        let range = selectedDateRange
        var values: [String: (GeoPoint, GeoPoint, Int, Bool, Date, TransportMode)] = [:]
        for track in filteredTracks {
            var seenInTrack = Set<String>()
            for pair in zip(track.displayPoints, track.displayPoints.dropFirst()) {
                guard pair.0.location.distance(from: pair.1.location) >= 2 else { continue }
                let transportMode = pair.1.resolvedTransportMode
                let visitedAt = min(pair.0.timestamp, pair.1.timestamp)
                guard visitedAt >= range.lowerBound, visitedAt <= range.upperBound else { continue }
                let roadKey = SegmentKey.make(pair.0, pair.1)
                let key = "\(roadKey)|\(transportMode.rawValue)"
                let isEstimated = track.containsEstimatedData || pair.0.estimated || pair.1.estimated
                guard seenInTrack.insert(key).inserted else { continue }
                if let current = values[key] {
                    // 同じ道路に一度でも実測記録があれば、実線を優先する。
                    values[key] = (
                        current.0,
                        current.1,
                        current.2 + 1,
                        current.3 && isEstimated,
                        min(current.4, visitedAt),
                        current.5
                    )
                } else {
                    values[key] = (pair.0, pair.1, 1, isEstimated, visitedAt, transportMode)
                }
            }
        }
        let result = values.map { key, value in
            WeightedSegment(
                id: key,
                start: value.0.coordinate,
                end: value.1.coordinate,
                frequency: value.2,
                isEstimated: value.3,
                firstVisitedAt: value.4,
                transportMode: value.5
            )
        }.sorted { $0.firstVisitedAt < $1.firstVisitedAt }
        cachedSegmentsKey = key
        cachedSegments = result
        return result
    }

    var weightedSegments: [WeightedSegment] {
        allWeightedSegments.filter { visibleTransportModes.contains($0.transportMode) }
    }

    var estimatedTrackCount: Int {
        tracks.filter(\.containsEstimatedData).count
    }

    var stats: WalkStats {
        let visibleModeKey = visibleTransportModes.map(\.rawValue).sorted().joined(separator: ",")
        let key = "\(derivedCacheKey)|\(liveRawPointsRevision)|\(visibleModeKey)"
        if cachedStatsKey == key { return cachedStats }
        guard !visibleTransportModes.isEmpty else {
            cachedStatsKey = key
            cachedStats = .zero
            return .zero
        }

        let range = selectedDateRange
        let measured = RecordedDistanceCalculator.summarize(
            tracks: tracksForDisplay, livePoints: liveRawPoints,
            range: range, modes: visibleTransportModes, calendar: calendar
        )
        var firstSeen: [String: Date] = [:]
        var visibleKeys = Set<String>()
        for track in tracksForDisplay.sorted(by: { $0.startDate < $1.startDate }) {
            for pair in zip(track.displayPoints, track.displayPoints.dropFirst()) {
                let transportMode = pair.1.resolvedTransportMode
                guard visibleTransportModes.contains(transportMode) else { continue }
                let roadKey = SegmentKey.make(pair.0, pair.1)
                let visitedAt = min(pair.0.timestamp, pair.1.timestamp)
                if firstSeen[roadKey] == nil { firstSeen[roadKey] = visitedAt }
                guard visitedAt >= range.lowerBound, visitedAt <= range.upperBound else { continue }
                let segmentDistance = pair.0.location.distance(from: pair.1.location)
                guard segmentDistance >= 2 else { continue }
                visibleKeys.insert(roadKey)
            }
        }
        let newRoads = visibleKeys.filter { roadKey in
            guard let date = firstSeen[roadKey] else { return false }
            return date >= range.lowerBound && date <= range.upperBound
        }.count
        let result = WalkStats(newRoads: newRoads, distance: measured.distance, activeDays: measured.activeDays.count)
        cachedStatsKey = key
        cachedStats = result
        return result
    }

    private var derivedCacheKey: String {
        let day = calendar.startOfDay(for: Date()).timeIntervalSince1970.bitPattern
        return "\(tracksRevision)|\(day)|\(period.rawValue)|\(rangeStartFraction.bitPattern)|\(rangeEndFraction.bitPattern)"
    }

    private func invalidateDerivedCaches() {
        cachedSegmentsKey = nil
        cachedStatsKey = nil
    }

    private func calculateReviewEligibleActiveDays(from tracks: [WalkTrack]) -> Int {
        #if DEBUG
        let eligibleTracks = tracks.filter {
            !SampleHistory.isKorakuenPreviewSample($0)
                && !SampleHistory.isShinjukuPreviewSample($0)
        }
        #else
        let eligibleTracks = tracks
        #endif

        var days = Set<Date>()
        for track in eligibleTracks {
            for pair in zip(track.rawPoints, track.rawPoints.dropFirst()) {
                guard pair.0.location.distance(from: pair.1.location) >= 2 else { continue }
                days.insert(calendar.startOfDay(for: min(pair.0.timestamp, pair.1.timestamp)))
            }
        }
        return days.count
    }

    var selectedRangeLabel: String {
        if period == .today {
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: appLanguage.localeIdentifier)
            dateFormatter.setLocalizedDateFormatFromTemplate("M/d")
            let timeFormatter = DateFormatter()
            timeFormatter.locale = Locale(identifier: appLanguage.localeIdentifier)
            timeFormatter.setLocalizedDateFormatFromTemplate("H:mm")
            return "\(dateFormatter.string(from: selectedDateRange.lowerBound))  \(timeFormatter.string(from: selectedDateRange.lowerBound)) — \(timeFormatter.string(from: selectedDateRange.upperBound))"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage.localeIdentifier)
        formatter.setLocalizedDateFormatFromTemplate("M/d")
        return "\(formatter.string(from: selectedDateRange.lowerBound))  —  \(formatter.string(from: selectedDateRange.upperBound))"
    }

    func setRecordingMode(_ mode: RecordingMode) {
        recordingMode = mode
        if mode == .persistent && recorder.authorizationStatus == .authorizedWhenInUse {
            recorder.requestBackgroundAuthorization()
        } else if mode != .off && recorder.authorizationStatus == .notDetermined {
            recorder.requestForegroundAuthorization()
        }
    }

    func setMovementCaptureMode(_ mode: MovementCaptureMode) {
        movementCaptureMode = mode
    }

    func refreshCurrentLocation() {
        recorder.refreshCurrentLocation()
    }

    func toggleTransportMode(_ mode: TransportMode) {
        if visibleTransportModes.contains(mode) {
            visibleTransportModes.remove(mode)
        } else {
            visibleTransportModes.insert(mode)
        }
    }

    func deleteAllHistory() {
        tracks = []
        livePoints = []
        recoveryAnchor = nil
        historyStore.deleteAll()
    }

    func addSampleHistory() {
        tracks.append(contentsOf: SampleHistory.make())
        tracks.sort { $0.startDate < $1.startDate }
        historyStore.save(tracks)
        matchPendingTracksToRoads()
    }

    private func storeFinishedTrack(_ points: [GeoPoint]) {
        let newTrack = WalkTrack(rawPoints: points)
        tracks.append(newTrack)
        tracks.sort { $0.startDate < $1.startDate }
        historyStore.save(tracks)

        Task {
            let matched = await RoadMatchingService.shared.match(points)
            guard let index = tracks.firstIndex(where: { $0.id == newTrack.id }) else { return }
            tracks[index].matchedPoints = matched
            tracks[index].isRoadMatched = matched != points
            historyStore.save(tracks)
        }
    }

    private func handleAcceptedPoint(_ point: GeoPoint) {
        guard recordingMode == .persistent else { return }
        let previous = recoveryAnchor
        recoveryAnchor = point
        // 位置更新ごとの同期ファイル書き込みはUIスレッドを詰まらせ、
        // 大量描画時のボタン反応を遅くするため、復旧用アンカーだけ間引く。
        if Date().timeIntervalSince(lastRecoveryAnchorSaveDate) >= 15 {
            historyStore.saveRecoveryAnchor(point)
            lastRecoveryAnchorSaveDate = Date()
        }

        guard let previous else { return }
        let gap = point.timestamp.timeIntervalSince(previous.timestamp)
        let directDistance = previous.location.distance(from: point.location)

        // 連続測位では埋まらなかった区間だけを対象にする。長時間・長距離すぎる移動は
        // 飛行機など道路経路を推定できない可能性が高いため、誤った線を作らない。
        guard gap >= 180,
              gap <= 24 * 60 * 60,
              directDistance >= 100,
              directDistance <= 200_000 else { return }

        var start = previous
        var end = point
        start.isEstimated = true
        end.isEstimated = true
        let averageSpeedMetersPerSecond = directDistance / max(1, gap)
        if averageSpeedMetersPerSecond * 3.6 >= 15 {
            // 地下鉄・電車など、GPSが途切れたまま長距離を移動した区間も車カテゴリへ統合する。
            start.transportMode = .automotive
            end.transportMode = .automotive
            start.speed = max(start.speed, averageSpeedMetersPerSecond)
            end.speed = max(end.speed, averageSpeedMetersPerSecond)
        }
        let rawPoints = [start, end]
        let inferredTrack = WalkTrack(rawPoints: rawPoints, isEstimated: true)

        // まず端点を保存し、道路検索の途中で再び終了されても復元対象を失わないようにする。
        tracks.append(inferredTrack)
        tracks.sort { $0.startDate < $1.startDate }
        historyStore.save(tracks)

        Task {
            let matched = await RoadMatchingService.shared.match(rawPoints)
            guard let index = tracks.firstIndex(where: { $0.id == inferredTrack.id }) else { return }
            tracks[index].matchedPoints = matched
            tracks[index].isRoadMatched = matched != rawPoints
            historyStore.save(tracks)
        }
    }

    private func clearRecoveryAnchorAfterSpeedFilter() {
        recoveryAnchor = nil
        historyStore.clearRecoveryAnchor()
    }

    private func updateLiveRoute(_ points: [GeoPoint]) {
        liveRawPoints = points
        liveRawPointsRevision &+= 1
        cachedStatsKey = nil
        guard !points.isEmpty else {
            historyStore.clearDraft()
            liveRoadMatchTask?.cancel()
            liveRoadMatchTask = nil
            liveMatchedPoints = []
            matchedRawPointCount = 0
            livePoints = []
            return
        }

        if Date().timeIntervalSince(lastDraftSaveDate) >= 15 {
            historyStore.saveDraft(points)
            lastDraftSaveDate = Date()
        }

        refreshLiveDisplay()
        scheduleLiveRoadMatchIfNeeded()
    }

    private func scheduleLiveRoadMatchIfNeeded() {
        guard liveRoadMatchTask == nil,
              liveRawPoints.count >= 2 else { return }

        let anchorIndex = min(max(0, matchedRawPointCount - 1), liveRawPoints.count - 1)
        let distanceSinceMatch = liveRawPoints[anchorIndex].location.distance(from: liveRawPoints.last!.location)
        guard distanceSinceMatch >= 70 else { return }

        let snapshot = liveRawPoints
        liveRoadMatchTask = Task {
            let matched = await RoadMatchingService.shared.match(snapshot)
            guard !Task.isCancelled else { return }
            liveMatchedPoints = matched
            matchedRawPointCount = snapshot.count
            liveRoadMatchTask = nil
            refreshLiveDisplay()
            scheduleLiveRoadMatchIfNeeded()
        }
    }

    private func refreshLiveDisplay() {
        guard !liveMatchedPoints.isEmpty else {
            livePoints = liveRawPoints
            return
        }

        var display = liveMatchedPoints
        let tailStart = min(max(0, matchedRawPointCount - 1), liveRawPoints.count)
        for point in liveRawPoints.dropFirst(tailStart) {
            guard let last = display.last,
                  last.location.distance(from: point.location) >= 1 else { continue }
            display.append(point)
        }
        livePoints = display
    }

    private func matchPendingTracksToRoads() {
        let pendingTracks = tracks.filter { !$0.isRoadMatched && $0.rawPoints.count > 1 }
        guard !pendingTracks.isEmpty else { return }

        Task {
            for pending in pendingTracks {
                let matched = await RoadMatchingService.shared.match(pending.rawPoints)
                guard matched != pending.rawPoints,
                      let index = tracks.firstIndex(where: { $0.id == pending.id }) else { continue }
                tracks[index].matchedPoints = matched
                tracks[index].isRoadMatched = true
                historyStore.save(tracks)
            }
        }
    }
}

enum SampleHistory {
    static var shinjukuLocation: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 35.6896, longitude: 139.7006),
            altitude: 0,
            horizontalAccuracy: 12,
            verticalAccuracy: -1,
            course: -1,
            speed: 0,
            timestamp: Date()
        )
    }

    static func makeShinjuku(now: Date = Date()) -> [WalkTrack] {
        // 新宿駅を起点に、都庁・歌舞伎町・新宿御苑・代々木・大久保方面へ広がるデモ用ルート。
        // 交差点を共有させ、頻度の濃淡と「新しい道」が画面上で出るようにする。
        let routes: [[(Double, Double)]] = [
            [(35.6896, 139.7006), (35.6904, 139.7020), (35.6921, 139.7025), (35.6940, 139.7022)],
            [(35.6896, 139.7006), (35.6890, 139.6982), (35.6895, 139.6958), (35.6910, 139.6948)],
            [(35.6896, 139.7006), (35.6878, 139.7008), (35.6858, 139.7012), (35.6840, 139.7020)],
            [(35.6896, 139.7006), (35.6892, 139.7032), (35.6879, 139.7050), (35.6866, 139.7054)],
            [(35.6896, 139.7006), (35.6913, 139.6993), (35.6930, 139.6982), (35.6952, 139.6980)],
            [(35.6896, 139.7006), (35.6886, 139.6978), (35.6868, 139.6965), (35.6852, 139.6978), (35.6860, 139.6995)],
            [(35.6896, 139.7006), (35.6880, 139.6990), (35.6856, 139.6975), (35.6834, 139.6985), (35.6824, 139.7003)],
            [(35.6896, 139.7006), (35.6910, 139.7045), (35.6920, 139.7070), (35.6905, 139.7083), (35.6885, 139.7074)],
            [(35.6896, 139.7006), (35.6921, 139.7025), (35.6945, 139.7040), (35.6965, 139.7030), (35.6975, 139.7005)],
            [(35.6896, 139.7006), (35.6910, 139.6948), (35.6930, 139.6933), (35.6952, 139.6940), (35.6965, 139.6962)],
            [(35.6896, 139.7006), (35.6884, 139.7035), (35.6865, 139.7040), (35.6847, 139.7032), (35.6838, 139.7050)],
            [(35.6896, 139.7006), (35.6904, 139.7020), (35.6921, 139.7025), (35.6938, 139.7007), (35.6950, 139.6989)],
            [(35.6896, 139.7006), (35.6878, 139.7008), (35.6860, 139.6995), (35.6848, 139.6974), (35.6837, 139.6962)],
            [(35.6896, 139.7006), (35.6913, 139.6993), (35.6930, 139.6982), (35.6942, 139.6965), (35.6960, 139.6958)],
            [(35.6896, 139.7006), (35.6892, 139.7032), (35.6910, 139.7045), (35.6930, 139.7058), (35.6948, 139.7072)],
        ]
        let modes: [TransportMode] = [
            .walking, .walking, .walking, .walking, .cycling,
            .walking, .cycling, .automotive, .walking, .automotive,
            .walking, .walking, .cycling, .automotive, .walking
        ]

        let localRoutes = routes.enumerated().map { index, route in
            let dayOffset = (index * 2) % 10
            let dayStart = Calendar.current.date(byAdding: .day, value: -dayOffset, to: now) ?? now
            // 当日分だけは未来のタイムスタンプを作らず、今この瞬間までに完了した経路にする。
            let start = dayOffset == 0
                ? now.addingTimeInterval(-Double(max(1, route.count - 1) * 150))
                : dayStart
            let mode = modes[index % modes.count]
            let speed: Double = switch mode {
            case .walking: 1.35
            case .cycling: 5.0
            case .automotive: 12.0
            }
            let points = route.enumerated().map { pointIndex, coordinate in
                GeoPoint(
                    latitude: coordinate.0,
                    longitude: coordinate.1,
                    timestamp: start.addingTimeInterval(Double(pointIndex) * 150),
                    horizontalAccuracy: 9,
                    speed: speed,
                    transportMode: mode
                )
            }
            return WalkTrack(rawPoints: points, createdAt: start, isRoadMatched: false)
        }
        return localRoutes + makeNorthernStationRoutes(now: now)
    }

    private static func makeNorthernStationRoutes(now: Date) -> [WalkTrack] {
        // Encoded walking polylines returned by MapKit for the station-to-station routes.
        // Keeping the routed geometry in the simulator fixture avoids partial route-matching
        // failures that previously hid the entire trip or left only a short fragment visible.
        let shinjukuToOkubo = #"_syxE_htsYa@B?@RtBB@JFDB@TC@CBUDKBeBPeBJ?B?DG?m@DGv@e@GoCa@M@y@BoE\EICIG?}@BAI?ICAIC_Bd@gBf@iAL[?yBSaB@iAJwCj@{@T?A?QHC?BaAV?@C@AEHA?LsAh@_Ab@i@Pe@RgBbAaBx@MFo@ZQH"#
        let shinjukuToShinOkubo = #"_syxE_htsYa@B?@RtBB@JFDB@TC@CBUDKBeBPeBJ?B?DG?m@DGv@e@GoCa@M@y@BoE\EICIG?}@BAI?ICAIC_Bd@gBf@iAL[?yBSaB@iAJwCj@{@T?A?QHC?BaAV?@C@AEHEA_DiA?aAAuAEmAE?C?CiEm@kBC"#
        let shinjukuToTakadanobaba = #"_syxE_htsYJAACIcAD?Gu@C?Eg@E@I@?AIy@EEsAb@uBt@U@mDVEF?H@b@m@@GGUFW?ABKHe@RINQJq@P}@NG?MES[C[@WGAy@K?DIr@s@PiEt@yAJ_AGcAKoA?iBGKC_CIGKCC?IG?g@@AJEHI@}BIw@CoAM?DARCAqAG]Bc@A}Di@EBKDQACGCGICwEUcFWw@CE?OAkAMmX}GWQgAqAM?A@CEc@e@If@Gh@CA_@IaA[cCq@aBa@o@]GCCBOAOdAA?_@Mm@S"#
        let okuboToTakadanobaba = #"qx{xEsrssYeB`AeAv@ACEOA?GF?[TuGEAQ?@_@DwAiA@sCAqHI?CDuALcC@E?S?EC?KA@c@@WEK_@KsCq@aJyBaK_CCCWG_@Ie@Mg@a@GE?BE?D@?BMr@MCOA[I}@YW[m@{@UMiAYkBc@?CBOA?_@Mm@S"#
        let shinOkuboToTakadanobaba = #"y{{xEedtsYAVI?Y??ABYG?OAAVCVEBc@C{DQACGCGD}@E}@GAAMCEB_@C_BI?E?EC?KA@c@@WEK_@KsCq@aJyBaK_CCCWG_@Ie@Mg@a@GE?BE?D@?BMr@MCOA[I}@YW[m@{@UMiAYkBc@?CBOA?_@Mm@S"#
        let takadanobabaToToyamaPark = #"c_~xEmytsYj@N@DF@XHDUHq@@@JBDEj@XJF`Dx@fCt@`@JFi@Hg@BBb@f@@ABA@KF[CI@QJy@HKNQDA?EDIHOhBCBE?CBO@ALBd@m@PKVCF@TIPOHQHOFHDFKL"#
        let takadanobabaToNishiWaseda = #"c_~xEmytsYj@N@DF@XHDUHq@@@JBDEj@XJF`Dx@fCt@`@JFi@Hg@BBb@f@@ABA@KF[CI@QJy@HKNQDA?EDIHOhBCBE?CBO@ALBd@m@PKVCF@TIPOHQHOJEl@CpCB?G?SX@?CFiHD??E@m@"#
        let takadanobabaToGakushuin = #"c_~xEmytsYuGaBAB?BICMC@CF]BICAQKKEBKJc@ECSOBG@Gu@e@OEo@O@g@C?aBMaAE?G@SYAiBKIGAG@IEAa@KHi@Js@k@BmFL?@O`AAAMCEBuBi@cEmAyAc@cG}A{Ac@EG@AJGPUP_@RWr@S\SD@pEv@"#
        let takadanobabaToOmokagebashi = #"c_~xEmytsYuGaBAB?BICMC@CF]BICAQKKEBKJc@ECSOBGZ_ACOBEFSOCOEVkA\_B?c@Gi@YiDBm@B?D@@o@P_MBoB_Ao@@GAAgB}@@GJ[GK?MFOpAqDBOpCmHR{@CAWC@CDU"#
        let takadanobabaToBabaPark = #"c_~xEmytsYj@N@DF@XHADALNDdDv@HFJDx@jAKf@@T@TLb@e@Xe@X_@^@?HH@F?R@L@@JD"#
        let takadanobabaToMejiro = #"c_~xEmytsYuGaBAB?BICMC@CF]BICAQKKEAFCJMv@G?UA?A?CG?k@^IFg@r@U`@CDWKWMOAQCgBRuCF?B?HIA[E?GCKaAWa@Me@G?CAc@EQc@{@IYGa@GaAAs@E?{@UME_EcAw@U{Dq@mAY"#

        let directOkubo = decodePolyline(shinjukuToOkubo)
        let directShinOkubo = decodePolyline(shinjukuToShinOkubo)
        let directTakadanobaba = decodePolyline(shinjukuToTakadanobaba)
        let viaOkubo = directOkubo + Array(decodePolyline(okuboToTakadanobaba).dropFirst())
        let viaShinOkubo = directShinOkubo + Array(decodePolyline(shinOkuboToTakadanobaba).dropFirst())
        let stationBranches = [
            takadanobabaToToyamaPark,
            takadanobabaToNishiWaseda,
            takadanobabaToGakushuin,
            takadanobabaToOmokagebashi,
            takadanobabaToBabaPark,
            takadanobabaToMejiro
        ].map(decodePolyline)
        let routes = [
            directOkubo,
            directShinOkubo,
            directTakadanobaba,
            viaOkubo,
            viaShinOkubo,
            directTakadanobaba
        ] + stationBranches

        return routes.enumerated().map { index, coordinates in
            let dayOffset = (index % 9) + 1
            let day = Calendar.current.date(byAdding: .day, value: -dayOffset, to: now) ?? now
            let start = Calendar.current.date(bySettingHour: 8 + index, minute: 10, second: 0, of: day) ?? day
            var distance: CLLocationDistance = 0
            let cumulativeDistances = coordinates.enumerated().map { pointIndex, coordinate -> CLLocationDistance in
                if pointIndex > 0 {
                    distance += CLLocation(
                        latitude: coordinates[pointIndex - 1].latitude,
                        longitude: coordinates[pointIndex - 1].longitude
                    ).distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
                }
                return distance
            }
            let points = coordinates.enumerated().map { pointIndex, coordinate in
                GeoPoint(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    timestamp: start.addingTimeInterval(cumulativeDistances[pointIndex] / 1.25),
                    horizontalAccuracy: 6,
                    speed: 1.25,
                    transportMode: .walking
                )
            }
            return WalkTrack(
                rawPoints: points,
                matchedPoints: points,
                createdAt: start,
                isRoadMatched: true
            )
        }
    }

    private static func decodePolyline(_ encoded: String) -> [CLLocationCoordinate2D] {
        let values = Array(encoded.utf8)
        var index = 0
        var latitude = 0
        var longitude = 0
        var coordinates: [CLLocationCoordinate2D] = []

        func decodeValue() -> Int? {
            var result = 0
            var shift = 0
            while index < values.count {
                let value = Int(values[index]) - 63
                index += 1
                result |= (value & 0x1f) << shift
                shift += 5
                if value < 0x20 {
                    return (result & 1) == 1 ? ~(result >> 1) : result >> 1
                }
            }
            return nil
        }

        while index < values.count {
            guard let latitudeDelta = decodeValue(), let longitudeDelta = decodeValue() else { break }
            latitude += latitudeDelta
            longitude += longitudeDelta
            coordinates.append(CLLocationCoordinate2D(
                latitude: Double(latitude) / 100_000,
                longitude: Double(longitude) / 100_000
            ))
        }
        return coordinates
    }

    static func make(now: Date = Date()) -> [WalkTrack] {
        // 後楽園駅を共通点にする少数のアンカー。起動後にMapKitで実際の道路形状へ補正する。
        let routes: [[(Double, Double)]] = [
            [(35.7020, 139.7537), (35.7078, 139.7525), (35.7067, 139.7599)],
            [(35.7021, 139.7450), (35.7078, 139.7525), (35.7128, 139.7484)],
            [(35.7009, 139.7512), (35.7078, 139.7525), (35.7155, 139.7530)],
            [(35.7042, 139.7565), (35.7078, 139.7525), (35.7132, 139.7468)],
            [(35.7035, 139.7488), (35.7078, 139.7525), (35.7103, 139.7580)],
            [(35.7014, 139.7551), (35.7078, 139.7525), (35.7161, 139.7492)]
        ]
        let previewModes: [TransportMode] = [.walking, .cycling, .automotive]
        return routes.enumerated().map { routeIndex, route in
            let start = Calendar.current.date(byAdding: .day, value: -(routeIndex * 3 + 1), to: now) ?? now
            let transportMode = previewModes[routeIndex % previewModes.count]
            let speed: Double = switch transportMode {
            case .walking: 1.3
            case .cycling: 5.2
            case .automotive: 13.5
            }
            let points = route.enumerated().map { index, coordinate in
                GeoPoint(
                    latitude: coordinate.0,
                    longitude: coordinate.1,
                    timestamp: start.addingTimeInterval(Double(index) * 480),
                    speed: speed,
                    transportMode: transportMode
                )
            }
            return WalkTrack(rawPoints: points, createdAt: start, isRoadMatched: false)
        }
    }

    static func isLegacyStraightSample(_ track: WalkTrack) -> Bool {
        guard track.rawPoints.count >= 33,
              track.matchedPoints == track.rawPoints else { return false }
        return track.rawPoints.allSatisfy {
            abs($0.horizontalAccuracy - 8) < 0.001 && abs($0.speed - 1.2) < 0.001
        }
    }

    static func isKorakuenPreviewSample(_ track: WalkTrack) -> Bool {
        guard track.rawPoints.count == 3 else { return false }
        return track.rawPoints.contains {
            abs($0.latitude - 35.7078) < 0.000_01 &&
            abs($0.longitude - 139.7525) < 0.000_01
        }
    }

    static func isShinjukuPreviewSample(_ track: WalkTrack) -> Bool {
        guard track.rawPoints.count >= 4 else { return false }
        return track.rawPoints.contains {
            abs($0.latitude - 35.6896) < 0.000_1
                && abs($0.longitude - 139.7006) < 0.000_1
        }
    }
}

enum ReviewRequestTrigger: String {
    case onboarding
    case activeDay2
    case activeDay5
}

enum ReviewRequestPolicy {
    private static let onboardingPendingKey = "review.onboarding.pending"
    private static let onboardingRequestedKey = "review.onboarding.requested"
    private static let activeDay2RequestedKey = "review.activeDay2.requested"
    private static let activeDay5RequestedKey = "review.activeDay5.requested"

    static func markOnboardingCompleted() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: onboardingRequestedKey) else { return }
        defaults.set(true, forKey: onboardingPendingKey)
    }

    static func nextEligibleTrigger(activeDays: Int) -> ReviewRequestTrigger? {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: onboardingPendingKey),
           !defaults.bool(forKey: onboardingRequestedKey) {
            return .onboarding
        }
        if activeDays >= 5, !defaults.bool(forKey: activeDay5RequestedKey) {
            return .activeDay5
        }
        if activeDays >= 2, !defaults.bool(forKey: activeDay2RequestedKey) {
            return .activeDay2
        }
        return nil
    }

    static func markRequested(_ trigger: ReviewRequestTrigger) {
        let defaults = UserDefaults.standard
        switch trigger {
        case .onboarding:
            defaults.set(false, forKey: onboardingPendingKey)
            defaults.set(true, forKey: onboardingRequestedKey)
        case .activeDay2:
            defaults.set(true, forKey: activeDay2RequestedKey)
        case .activeDay5:
            defaults.set(true, forKey: activeDay5RequestedKey)
            // 5日目まで到達している場合、過去の2日目依頼を後追いで出さない。
            defaults.set(true, forKey: activeDay2RequestedKey)
        }
    }
}
